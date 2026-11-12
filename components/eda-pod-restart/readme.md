# Alertmanager to Event-Driven Ansible pod restart

Platform workaround for a bad application build. User-workload monitoring
watches the app, Alertmanager posts the firing alert to an Event-Driven
Ansible rulebook, and a controller job deletes that pod so its Deployment
starts a new one. Fixing the application is still the real work.

```
spring-boot-demo /actuator/prometheus
        |  Istio merges the series onto sidecar :15020
        v
user-workload Prometheus  -- SpringBootDemoHeapHigh (heap > 80% for 5m)
        v
user-workload Alertmanager
        |  POST the gateway event-stream URL
        |  Authorization: Bearer token from secret eda-webhook-token
        v
AAP gateway Token Event Stream
        |  forwards the body to the activation
        v
rulebook activation spring-boot-demo-pod-restart
        |  run_job_template restart-spring-boot-demo-pod
        v
controller job deletes the named pod
```

The controller credential is the `AnsibleCredential` custom resource
`openshift-pod-restart`. It names secret `eda-pod-restart-token` and reads
key `token`. That is the secret External Secrets can replace.

Two more secrets are inputs, not objects this repo creates. Create them after
the platform gateway answers, and before the `eda-pod-restart` application
syncs. The resource operator marks an Ansible custom resource finished when
`aap-access` is missing, and it does not try again.

`eda-pod-restart-token` and `aap-eda-bootstrap-token` are the exceptions.
This component creates those ServiceAccount token secrets, and OpenShift
fills the `token` key.

| Secret | Keys | Who reads it |
| --- | --- | --- |
| `aap/aap-access` | `token`, `host` | every Ansible custom resource, and the EDA credential that launches the job |
| `spring-boot-demo/eda-webhook-token` | `token` | AlertmanagerConfig, and `configure-aap.yml` copies it into the Token Event Stream credential |

```sh
PASS=$(oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk -u "admin:${PASS}" -H 'Content-Type: application/json' \
  -d '{"description":"eda-pod-restart","scope":"write"}' \
  https://aap.apps-crc.testing/api/gateway/v1/tokens/ \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
oc create secret generic aap-access -n aap \
  --from-literal=token="${TOKEN}" \
  --from-literal=host='https://aap.apps-crc.testing/'
oc create secret generic eda-webhook-token -n spring-boot-demo \
  --from-literal=token="$(openssl rand -hex 32)"
```

`host` is the gateway URL, with the trailing slash. The webhook value is a
static bearer token. It is not an AAP login token. Later, External Secrets
can own both secrets. After it changes `eda-webhook-token`, delete
`AnsibleJob` `configure-aap-eda` and the batch Job of the same name so the
playbook copies the new value.

`AnsibleJob` `configure-aap-eda` launches `configure-aap.yml` in AAP when
the custom resource is created. The job template credential
`aap-eda-bootstrap` can read `aap-access` and `eda-webhook-token`. The
resource operator does not re-read an `AnsibleCredential` secret after its
job finishes. To run the playbook again, delete `AnsibleJob`
`configure-aap-eda` and the batch Job of the same name. A finished
AnsibleJob does not launch a second time.

The activation is throttled to one restart per pod per 15 minutes.
Alertmanager repeats a still-firing alert every 30 minutes. The rule reads
`event.payload.commonLabels`, which is how Alertmanager labels one grouped
notification.

## What gets installed

`components/ansible-automation-platform` installs controller and
Event-Driven Ansible. Hub, Lightspeed, MCP, and the metrics service are
left off. The platform gateway is the UI:

- https://aap.apps-crc.testing
- OpenShift console, Application menu, Automation, Ansible Automation Platform
- user `admin`, password in secret `aap-admin-password` in namespace `aap`

Use that UI to watch the workaround:

- Automation Decisions, Rulebook Activations, then Rule Audit
- Automation Execution, Jobs
- Observe, Alerting, `SpringBootDemoHeapHigh`

## Objects

| Piece | Where |
| --- | --- |
| Rulebook | `rulebooks/spring-boot-demo-pod-restart.yml` (repo root; EDA only reads that directory) |
| Playbook | `playbooks/restart-pod.yml` |
| Restart job template | `jobtemplate-restart-spring-boot-demo-pod.yaml` |
| Controller project, inventory, Kubernetes credentials | `ansibleproject-eda-pod-restart.yaml`, `ansibleinventory-localhost.yaml`, `ansiblecredential-openshift-pod-restart.yaml`, `ansiblecredential-aap-eda-bootstrap.yaml` |
| Run `playbooks/configure-aap.yml` once | `jobtemplate-configure-aap-eda.yaml`, `ansiblejob-configure-aap-eda.yaml` |
| Event stream, EDA credential, EDA project, activation | that AAP job |
| PrometheusRule, AlertmanagerConfig, pod delete Role | `alert/prometheusrule-spring-boot-demo-heap.yaml`, `alert/alertmanagerconfig-eda-pod-restart.yaml`, `alert/role-eda-pod-restart.yaml` |

The job template credential is a token for ServiceAccount `eda-pod-restart`.
That account can get and delete pods in `spring-boot-demo` and nothing else.
The playbook also refuses a pod whose `app.kubernetes.io/name` is not
`spring-boot-demo`.

Push this repository to `main` before the controller project can see
`configure-aap.yml` and the rulebook. After later playbook edits, sync the
`eda-pod-restart` project from Automation Execution, then delete the
`AnsibleJob` so it runs again.

## Try the webhook without filling the heap

The 80% threshold stays quiet on an idle JVM. Post one Alertmanager payload
at the activation once it is Running:

```sh
POD=$(oc get pod -n spring-boot-demo -l app.kubernetes.io/name=spring-boot-demo -o jsonpath='{.items[0].metadata.name}')
TOKEN=$(oc get secret eda-webhook-token -n spring-boot-demo -o jsonpath='{.data.token}' | base64 -d)
oc run curl-eda --rm -it --restart=Never --image=registry.access.redhat.com/ubi9/ubi -- bash -c "
  curl -sk -D- -o /dev/null -X POST https://aap.apps-crc.testing/eda-event-streams/api/eda/v1/external_event_stream/c4e8a1d2-7b63-4f90-8e15-2a6d9c0b4f31/post/ \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '{\"receiver\":\"eda-pod-restart\",\"status\":\"firing\",\"commonLabels\":{\"alertname\":\"SpringBootDemoHeapHigh\",\"namespace\":\"spring-boot-demo\",\"pod\":\"${POD}\"},\"alerts\":[{\"status\":\"firing\",\"labels\":{\"alertname\":\"SpringBootDemoHeapHigh\",\"namespace\":\"spring-boot-demo\",\"pod\":\"${POD}\"},\"annotations\":{\"summary\":\"manual test\"},\"startsAt\":\"2026-11-09T00:00:00.000Z\",\"endsAt\":\"0001-01-01T00:00:00Z\"}]}'
"
```

A post without the bearer token gets HTTP 401 from the gateway. `sample-alert.json`
is the same body. The pod name in `commonLabels` is the pod that gets deleted.
A second post for the same pod inside 15 minutes is throttled.

To exercise the Prometheus rule, lower the `0.80` comparison in
`alert/prometheusrule-spring-boot-demo-heap.yaml` only for a value the JVM will fall back through
after a restart, then put it back. A threshold under the steady-state heap
deletes the pod on every repeat.
