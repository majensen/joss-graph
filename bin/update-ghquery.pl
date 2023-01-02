#!/usr/bin/env perl
use v5.10;
use lib 'lib';
use Mojo::URL;
use Log::Log4perl::Tiny qw/:easy build_channels/;
use JSON::ize;
use JOSS;
use strict;
use warnings;

binmode STDOUT, ":utf8";

my $IGNORE_BEFORE = 2378;

my $joss = JOSS->new();

pretty_json;

my $log = get_logger();
$log->fh( build_channels(
  fh => \*STDERR,
  file_append => $ENV{JGLOG} // 'jossgraph.log' ) );

# last issue recorded in db:
my $since_issn = $ENV{FROM_ISSUE} // $joss->latest_issn;

# last issue on GitHub:
my $last_issn = $ENV{TO_ISSUE} // $joss->get_last_issue_num;

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
my $issues = $joss->get_last_issues($nr);
unless ($issues) {
  $log->logcroak("get_last_issues() query failed. Aborting.");
}

# issues in db that need checking:
$log->info("Check old issues for updates");
for my $q ($joss->available_queries) {
  for my $issn ($joss->$q->members) {
    next if $issn < $IGNORE_BEFORE;
    next if $issues->{$issn};
    my $iss = $joss->get_issue_by_num($issn);
    unless ($iss) {
      $log->logcroak("get_issue_by_num($issn) query failed. Aborting.");
    }
    $issues->{$issn} = $iss;
  }
}

for my $issn ($joss->review_pending_no_topics->members) {
  next unless $issues->{$issn};
  my $iss = $issues->{$issn};
  if ($joss->get_paper_text($iss)) {
#    if ($ENV{DO_TOPIC_ANALYSIS}) { # short circuit topic analysis
      # do topic analysis on the pending review mss
      if (my @gamma = $joss->model_subm_topics($iss)) {
	my $i = 1;
	for my $g (@gamma) {
	  $iss->{topics}{"Topic $i"} = $g;
	  $i++;
	}
      }
#    }
  }
}

say J($issues);

1;
