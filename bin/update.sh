#!/bin/bash
update-ghquery.pl | load-update.pl | neo4j-client --insecure $NEO_URL 7687
