# Create a machineconfig that runs a script on worker nodes using systemd ono a schedule

Generate Maching config from butane...

```sh
butane 99-worker-myscript-job.bu -o 99-worker-myscript-job.yaml
```

Verify on node...

```sh
sh-5.1# systemctl status myscript 
○ myscript.service - My custom cron script service
     Loaded: loaded (/etc/systemd/system/myscript.service; static)
     Active: inactive (dead) since Tue 2025-12-02 18:00:00 UTC; 1min 20s ago
TriggeredBy: ● myscript.timer
    Process: 40599 ExecStart=/usr/local/bin/myscript.sh (code=exited, status=0/SUCCESS)
   Main PID: 40599 (code=exited, status=0/SUCCESS)
        CPU: 5ms

Dec 02 18:00:00 crc systemd[1]: Starting My custom cron script service...
Dec 02 18:00:00 crc systemd[1]: myscript.service: Deactivated successfully.
Dec 02 18:00:00 crc systemd[1]: Finished My custom cron script service.
```
