# JOSS-graph

Github scraping utilities for creating and maintaining a Neo4j graph database for [JOSS](https://joss.theoj.org) submission, review, and publication activities

A [Docker container](#Docker) is available containing the database and updaters.

# Database stats

TBD

# Background

The [Journal of Open Source Software](https://joss.theoj.org) is an open journal that publishes peer-reviewed scientific research software. All submissions, reviews, editing, and formal publications are performed online via Github repositories and user accounts.

JOSS [Topic Editors](https://joss.theoj.org/about#topic_editors) often choose reviewers from a [central list](https://docs.google.com/spreadsheets/d/1PAPRJ63yq9aPC1COLjaQp8mHmEq3rZUzwUYxTulyu78) of people who have agreed to review and have entered preference information, including preferred programming languages and areas of expertise. The list has grown to several hundred records and is cumbersome to use. It is sometimes of interest to know something about the review history of reviewers, the topics that submitters have written on (for the purpose of soliciting reviews from them), the frequency of reviews by a reviewer, and other information. This repo contains a graph model and scripts to slurp journal activity from the JOSS Github repos [joss-papers](https://github.com/openjournals/joss-papers) and [joss-reviews](https://github.com/openjournals/joss-reviews) into a [Neo4j](https://neo4j.com) graph database, so that it becomes easy to ask these questions.

# Model

The graph model is described in [joss-model.yaml](./joss-model.yaml). The format complies with the Model Description File format in [Bento](https://github.com/CBIIT/bento-mdf).

There are four main nodes:

 * person
 * assignment
 * submission
 * paper
 
## _person_ 

A _person_ node represents an individual. It records the following properties: 
 * _handle_ (Github handle)
 * _real\_name_ (full name if available)
 * _orcid_ ([ORCID](https://orcid.org/) if available)
 *  _email_ (if available)
 * _affiliation_ (if available)

Reviewers who have provided langugage and topic preferences have _person_ nodes linked to _language_ and _topic_ nodes. _language_ nodes possess the _name_ property, _topic_ nodes the _content_ property. The property values are normalized to lower case and use only spaces for whitespace.

## _submission_

A _submission_ node records an instance of formal submission to JOSS as an instantiated pre-review (and followup review) issue in [joss-reviews](https://github.com/openjournals/joss-reviews). It has the following properties:

 * _title_
 * _disposition_, one of (review\_pending, under\_review, paused, accepted, published, withdrawn, rejected, closed)
 * _joss_doi_
 * _repository_, URL of the submission's Github repo
 * _prerev\_issue_, URL of the submissions's pre-review issue
 * _review\_issue_, URL of the submissions's review issue (if any)

## _paper_

_paper_ nodes record the location and doi information of published submissions. A _paper_ is linked to its corresponding _submission_ via a _from\_submission_ relationship. It has the following properties.

 * _title_
 * _joss\_doi_
 * _archive\_doi_, [DOI](https://en.wikipedia.org/wiki/Digital_object_identifier) of the software archive for the paper, frequently found on [Zenodo](https://zenodo.org/)
 * _url_
 * _published\_date_ (MM-YYYY)
 * _volume_, JOSS volume number
 * _issue_, JOSS issue number


## _assignment_

The _assignment_ node records a single "encounter event" between a _person_ and a _submission_. They are linked to a single _person_ by an "assigned\_to" relationship, and to a signle _submission_ by an "assigned\_for" relationship. An _assignment_ node has the following properties:

 * _role_, one of (_author_, _submitter_, _reviewer_, _editor_, _eic_)
 
# Sample queries

 * Q. How many papers has JOSS published to date?

		match (p:paper) return count(p);
		
 * Q. How many authors are also reviewers?

		match (p:person)--(a:assignment {role:"author"}), (p)--(b:assignment {role:"reviewer"})
		return count( distinct p );
 
 * Q. Who are the top 10 all-time reviewers by papers reviewed?
 
		match (p:person)--(a:assignment {role:"reviewer"})
		return p.handle, count(a) as num_papers order by num_papers desc limit 10;
		
 * Q. Which potential reviewers have also published in JOSS with submitting author "labarba"?
 
		match (a:person {handle:"labarba"})--(:assignment {role:"author"})--(s:submission) with a, s
		match (p:person)--(:assignment {role:"author"})--(s) where (p) <> (a) and
		(p)--(:assignment {role:"reviewer"})
		return distinct a.handle as a, p.handle as h, p.orcid as o order by h;
		
 * Q. What is the current submission/publication ratio for JOSS Topic Editors?
 
		match (p:person)<--(:assignment {role:"editor"}) with distinct p as e
		match (e)--(:assignment {role:"editor"})--(s:submission) 
		optional match (s)--(b:paper)
		return e.handle, toFloat(count(b))*100.0/toFloat(count(s)) as ratio, count(s) as n
		order by n desc;

# Scripts

The following scripts are provided here to update a current Neo4j instance of JOSS-graph:

  * [update-ghquery.pl](./bin/update-ghquery.pl) - queries both the graph and the GitHub GraphQL (a.k.a. v4) endpoint to update submissions and publications
  
  * [load-update.pl](./bin/load-update.pl) - converts the JSON output of update-ghquery.pl into [Cypher](https://neo4j.com/docs/cypher-manual/current/) statements

  * [minisrv.pl](./bin/minisrv.pl) - provides a control server to perform updates automatically
  
These rely on the Perl modules in the [lib](./lib) directory. The machinery can be built locally by
cloning the repo, cd'ing to the main directory, and executing:
	
	curl -L https://cpanmin.us | perl - App::cpanminus
	cpanm Module::Build
	cpanm -n Time::Zone # avoids a current bug in TimeDate tests
	perl Build.PL
	./Build
	./Build installdeps --cpan_client cpanm
	./Build install
	
Using the Docker container is easier.

# Docker

Run the following command to instantiate JOSS-graph in a container:

	docker run -d -e "GHCRED=<your_github_pass_or_token>" \
	  -p 7474:7474 -p 7473:7473 -p 7687:7687 -p 3001:3001 maj1/fortinbras:joss-graph

Point a browser to https://localhost:7473 or http://localhost:7474 to explore the database.
The neo4j instance is configured to be accessed without authentication.

To update the database, perform a get request to http://localhost:3001/update. 

Remove the `-p 3001:3001` option from the `docker run` command to hide the control server, and perform updates with the following command:

	docker exec -it <container> curl http://localhost:3001/update
	
# License

Perl (GNU GPLv2 / Artistic License)
