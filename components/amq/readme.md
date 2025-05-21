# testing nodport to amq within mesh

> download client from https://activemq.apache.org/components/artemis/download/

```sh
tbox@fedora:~/Downloads/apache-artemis-2.41.0-bin/apache-artemis-2.41.0/bin$ ./artemis producer --user x --password y --url tcp://192.168.130.11:31443 --message-count=100
Connection brokerURL = tcp://192.168.130.11:31443
Producer ActiveMQQueue[TEST], thread=0 Started to calculate elapsed time ...

Producer ActiveMQQueue[TEST], thread=0 Produced: 100 messages
Producer ActiveMQQueue[TEST], thread=0 Elapsed time in second : 0 s
Producer ActiveMQQueue[TEST], thread=0 Elapsed time in milli second : 729 milli seconds
tbox@fedora:~/Downloads/apache-artemis-2.41.0-bin/apache-artemis-2.41.0/bin$ ./artemis producer --user x --password y --url tcp://192.168.130.11:31443?sslEnabled=true?trustAll=true --message-count=100
Connection brokerURL = tcp://192.168.130.11:31443?sslEnabled=true?trustAll=true
Producer ActiveMQQueue[TEST], thread=0 Started to calculate elapsed time ...

Producer ActiveMQQueue[TEST], thread=0 Produced: 100 messages
Producer ActiveMQQueue[TEST], thread=0 Elapsed time in second : 0 s
Producer ActiveMQQueue[TEST], thread=0 Elapsed time in milli second : 435 milli seconds
```
