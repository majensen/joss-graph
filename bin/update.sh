#!/bin/bash
# update jossgraph, push log into syslog
curl http://$NEO_URL:7687
if (( $? == 52 ))
then
     update-ghquery.pl | load-update.pl | neo4j-client --insecure $NEO_URL 7687
     logger -p jossgraph.info -f minisrv.log
else
  logger -p jossgraph.error "[ERROR] Neo4j server is not responding - update aborted"
fi

