#!/bin/bash
perlbrew init
source ~/perl5/perlbrew/etc/bashrc
perlbrew switch perl-5.24.4
minisrv.pl daemon -l "http://*:3001" &
exec neo4j console

