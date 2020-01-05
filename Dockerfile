# to start the graph db, do
# docker run -p 7473:7473 -p 7687:7687 -p 3001:3001 -d maj1/fortinbras:joss-graph
# browse to 127.0.0.1:7473, select "No Authentication", and click "Connect"
FROM maj1/fortinbras:perlbrew-base
EXPOSE 7473 7687 3001
ARG perl=perl-5.24.4
RUN set -eux ; \
	curl https://debian.neo4j.org/neotechnology.gpg.key | apt-key add - ; \
	echo 'deb http://debian.neo4j.org/repo stable/' | tee -a /etc/apt/sources.list ; \
	apt-get update -qq ; \
	apt-get install -y daemon adduser psmisc lsb-base openjdk-8-jdk libssl-dev ; \
	echo N | apt-get -y install neo4j=1:3.5.14 ;
WORKDIR /opns
COPY Build.PL .
COPY MANIFEST .
COPY README.md .
COPY bin bin
COPY lib lib
RUN apt-get install -y zlib1g-dev libexpat1-dev
RUN /bin/bash --login -c 'perlbrew switch ${perl} ; \
        cpanm Module::Build ; \
        cpanm -n --force Time::Zone ; \
	perl Build.PL ; \
	./Build ; \
	./Build installdeps --cpan_client cpanm ; \
        ./Build install ; \
	./Build realclean ;'
COPY start.sh .
COPY initial_load/neo4j.conf ../etc/neo4j/neo4j.conf 
COPY initial_load/joss-graph.dmp .
RUN neo4j-admin load --from=joss-graph.dmp
ENTRYPOINT ["./start.sh"]
        
