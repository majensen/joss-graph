# docker run -d -v$PWD/logs:/var/log --rm --env-file runenv maj1/jg_manager:latest
FROM ubuntu:lunar
LABEL author=maj@fortinbras.us
ENV NEO_URL set_at_run
ENV NEOUSER set_at_run
ENV NEOPASS set_at_run
ENV GHCRED set_at_run
# required for neo4j-client to work:
ENV LD_LIBRARY_PATH=/usr/local/lib
WORKDIR /opns
RUN apt-get update -qq
RUN apt-get install -y curl
# time zone package hangs - requires input (Americas/NewYork here)
RUN echo 2$'\n'106 | apt install tzdata
RUN apt-get install -y git emacs-nox cpanminus
RUN apt-get install -y r-cran-tidyverse r-cran-optparse
RUN apt-get install -y r-cran-tidytext r-cran-tm r-cran-slam
# to build topicmodels R package
RUN apt-get install -y libgsl-dev 
# to build JOSS-graph
RUN apt-get install -y zlib1g-dev libexpat1-dev
# to build neo4j-client
RUN apt-get install -y libcypher-parser8 libedit-dev 
RUN apt-get install -y autoconf libtool libedit-dev libssl-dev
RUN apt-get install -y libcypher-parser-dev
RUN git clone https://github.com/majensen/joss-graph
WORKDIR /opns/joss-graph
# install topicmodels package
RUN echo 'install.packages(c("topicmodels"),repos=c("https://cloud.r-project.org"))' > inst-topic.r
RUN Rscript inst-topic.r
WORKDIR /opns
RUN git clone https://github.com/majensen/libneo4j-client
WORKDIR libneo4j-client
RUN autoreconf --install
RUN LDFLAGS="-L/usr/local/lib" ./configure --disable-werror
RUN make install
WORKDIR /opns/joss-graph
RUN cpanm Module::Build 
RUN cpanm -n --force Time::Zone
RUN perl Build.PL
RUN ./Build
RUN ./Build installdeps --cpan_client cpanm 
RUN ./Build install
RUN ./Build realclean
WORKDIR /opns
ENTRYPOINT ["/bin/bash", "update.sh"]
