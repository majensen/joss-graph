#!/usr/bin/env perl
use v5.10;
use lib 'lib';
use Mojo::URL;
use Log::Log4perl::Tiny qw/:easy build_channels/;
use JSON::ize;
use JOSS qw/$nq latest_issn get_issue_by_num get_last_issue_num get_last_issues get_paper_text model_subm_topics find_prerev_for_rev find_xml_for_accepted/;
use strict;
use warnings;

our $nq;
$ENV{NEODSN}='dbi:Neo4p:db=http://localhost:7474';

pretty_json;

my $log = get_logger();
$log->fh( build_channels( file_append => 'minisrv.log' ) );

# last issue recorded in db:
my $since_issn = $ENV{FROM_ISSUE} // latest_issn();

# last issue on GitHub:
my $last_issn = $ENV{TO_ISSUE} // get_last_issue_num();

unless ($last_issn) {
  $log->logcroak("Couldn't query repo for last issue");
}
unless ($last_issn > $since_issn) {
  $log->logcarp("arg (latest issue in db) >= last issue in repo");
  say J({});
  exit 1;
}

my $nr = $last_issn - $since_issn; # number to retrieve

$log->info("Get the $nr latest issues");
my $issues = get_last_issues($nr);

# issues in db that need checking:
$log->info("Check old issues for updates");
for my $q ($nq->available_queries) {
  for my $issn ($nq->$q) {
    my $iss = get_issue_by_num($issn);
    if ($iss) {
      get_paper_text($iss);
      $issues->{$issn} = $iss;
      if ($ENV{DO_TOPIC_ANALYSIS}) { # short circuit topic analysis
	# do topic analysis on the pending review mss
	if (my @gamma = model_subm_topics($iss)) {
	  my $i = 1;
	  for my $g (@gamma) {
	    $iss->{topics}{"Topic $i"} = $g;
	    $i++;
	  }
	}
      }
    }
  }
}

say J($issues);

1;
