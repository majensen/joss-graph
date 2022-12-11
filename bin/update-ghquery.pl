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

my $issues = get_last_issues($nr);

# issues in db that need checking:

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

for my $issn (sort {$a <=> $b} keys %$issues) {
  my $ent = $issues->{$issn};
  if ($ent->{title} =~ /^\s*\[REVIEW/) {
    my $prn = find_prerev_for_rev($issn);
    $ent->{prerev} = $prn if $prn;
    if ($ent->{disposition} eq 'accepted') { # get publication info
      my $xrf = find_xml_for_accepted($issn);
      if ($xrf) {
	$ent->{disposition} = 'published';
	my $p = {};
	$$p{authors} = $xrf->get_authors;
	$$p{published_date} = $xrf->get_pubdate;
	$$p{title} = $xrf->get_title;
	$$p{review_issue} = $xrf->get_review_issue;
	@{$p}{qw/volume issue/} = @{$xrf->get_vol_issue}{qw/volume issue/};
	@{$p}{qw/joss_doi archive_doi url/} = @{$xrf->get_dois}{qw/jdoi adoi url/};
	$ent->{paper} = $p;
      }
      else {
	$log->info("Issue $issn - accepted but crossref.xml not found");
      }
    }
  }
}

say J($issues);

1;
