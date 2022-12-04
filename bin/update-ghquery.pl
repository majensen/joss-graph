#!/usr/bin/env perl
use v5.10;
use lib 'lib';
use utf8::all;
use Net::GitHub::V4;
use Mojo::URL;
use Mojo::UserAgent;
use Try::Tiny;
use Log::Log4perl::Tiny qw/:easy build_channels/;
use JOSS::GHQueries;
use JOSS::WhedonSlurp;
use JOSS::Crossref;
use JOSS::NeoQueries;
use JSON::ize;
use IPC::Run qw/run timeout/;
use File::Path qw/rmtree/;
use strict;
use warnings;

$ENV{NEODSN}='dbi:Neo4p:db=http://localhost:7474';

sub CHUNK { 10 }
pretty_json;

my $log = get_logger();
$log->fh( build_channels( file_append => 'minisrv.log' ) );
my $nq = JOSS::NeoQueries->new();
my $wd = JOSS::WhedonSlurp->new();
my $ua = Mojo::UserAgent->new();
my $pw = $ENV{GHCRED};
my ($in, $out, $err);

unless ($pw) {
  if ( -e "$ENV{HOME}/.git-credentials" ) {
    open my $cred, "$ENV{HOME}/.git-credentials" or $log->logdie("Problem with .git-credentials: $!");
    my @cred = <$cred>;
    $pw = Mojo::URL->new($cred[0])->password;
  }
}

my $ng = Net::GitHub::V4->new(
  access_token => $pw,
 );
my $dta;

# last issue recorded in db:
my $since_issn = $nq->latest_issn;

# last issue on GitHub:
my $last_issn = get_last_issue_num();

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

my @no_topics;

for my $q ($nq->available_queries) {
  for my $issn ($nq->$q) {
    my $iss = get_issue_by_num($issn);
    if ($iss) {
      $issues->{$issn} = $iss;
      push @no_topics, $issn if ($q =~ /no_topics/);
    }
  }
}

if ($ENV{DO_TOPIC_ANALYSIS}) { # short circuit topic analysis
# do topic analysis on the pending review mss
for (@no_topics) {
  my $ent = $issues->{$_};
  if (my @gamma = model_subm_topics($ent)) {
    my $i = 1;
    for my $g (@gamma) {
      $ent->{topics}{"Topic $i"} = $g;
      $i++;
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

sub get_last_issues {
  my ($nr) = @_;
  my $dta;
  my $cursor;
  my %issues;
  while ($nr > 0) {
    my $c = ($nr < CHUNK ? $nr : CHUNK);
    try {
      $dta = $ng->query( make_qry('last_n_issues',
				  { chunk => $c,
				    cursor => $cursor}));
    } catch {
      $log->logcarp("last_n_issues query failed: $_");
      last;
    };
    for my $item ( @{$dta->{data}{organization}{repository}{issues}{nodes}} ) {
      my $ent;
      $ent->{number} = $item->{number};
      $ent->{title} = $item->{title};
      $ent->{url} = $item->{url};
      $ent->{info} = $wd->parse_issue_body( $item->{body}, $item->{number} );
      next unless ($ent->{info});
      for my $l (@{$item->{labels}{nodes}}) {
	push @{$ent->{labels}}, $l->{name};
      }
      $ent->{disposition} = dispo([map {$_->{name}} @{$item->{labels}{nodes}}],$item->{state});
      
      $issues{$ent->{number}} = $ent;
    }
    $cursor = $dta->{data}{organization}{repository}{issues}{pageInfo}{startCursor};
    $nr -= $c;
  }
  return \%issues;
}

sub get_issue_by_num {
  my ($num) = @_;
  my $dta;
  try {
    $dta = $ng->query( make_qry('issue_by_number', { number => $num }) );
  } catch {
    $log->logcarp("issue_by_number query failed: $_");
    return;
  };
  my $item = $dta->{data}{organization}{repository}{issue};
  my $ent;
  $ent->{number} = $item->{number};
  $ent->{title} = $item->{title};
  $ent->{url} = $item->{url};
  $ent->{info} = $wd->parse_issue_body( $item->{body} );
  for my $l (@{$item->{labels}{nodes}}) {
    push @{$ent->{labels}}, $l->{name};
  }
  $ent->{disposition} = dispo([map {$_->{name}} @{$item->{labels}{nodes}}],$item->{state});
  return $ent;
}

sub get_last_issue_num {
  my $dta;
  try {
    $dta = $ng->query( make_qry('last_issue_number') );
  } catch {
    $log->logcarp("last_issue_number query failed: $_");
    return;
  };
  return 0+${$dta->{data}{organization}{repository}{issues}{nodes}}[0]->{number};
}

sub find_prerev_for_rev {
  my ($issn) = @_;
  try {
    $dta = $ng->query( make_qry('prereview_issue_by_review_issue', { number => $issn } ) );
  } catch {
    $log->logcarp("prereview_issue_by_review_issue: query on $issn failed: $_");
  };
  my $nodes = $dta->{data}{organization}{repository}{issue}{timelineItems}{edges};
  for (@$nodes) {
    my $src = $_->{node}{source};
    if ($src->{author}{login} =~ /whedon|editorialbot/ and $src->{title} =~ /^\s*\[PRE\s*REVIEW\]/) {
      return 0+$src->{number};
    }
  }
  $log->logcarp("No pre-review issue found for $issn");
  return;
}

sub find_xml_for_accepted {
  my ($issn) = @_;
  try {
    $dta = $ng->query( make_qry('last_n_comments_of_issue', { number => $issn, chunk => 15 } ) );
  } catch {
    $log->logcarp("last_n_comments_of_issue: query on $issn failed: $_");
    next;
  };
  my @cmts = @{$dta->{data}{organization}{repository}{issue}{comments}{nodes}};
  my @whd = grep { $_->{author}{login} =~ /whedon|editorialbot/ and $_->{body} =~ /NOT A DRILL/ } @cmts;
  if (@whd) {
    my $info;
    my $txt = $whd[0]{body};
    $txt =~ m|(https://github.com/openjournals/joss-papers/pull/([0-9]+)).*
	      (https://doi.org/(10.21105)/(joss.([0-9]+)))|sx;
    @{$info}{qw/pull pull_issue doi pfx sfx ppr_issue/} = ($1,$2,$3,$4, $5, 0+$6);
    
    my $stem = "https://github.com/openjournals/joss-papers/raw/master";
    my $url = join('/', $stem, $info->{sfx}, join('.',$info->{pfx},$info->{sfx},"crossref.xml"));
    my $res = $ua->max_redirects(5)->get($url)->result; # ->content->asset->move_to(<file>)
    if ($res->is_success) {
      my $xrf = JOSS::Crossref->new($res);
      return $xrf;
      1;
    }
    else {
      $log->logcarp("Couldn't retrieve '$url' - status ".$res->code);
      return;
    }
      
    1;
  }
  else {
    return;
  }
  
}

# determine disposition from review labels
sub dispo {
  my ($labels, $state) = @_;
  my $dispo;
  if ( grep /withdrawn/, @$labels ) {
    $dispo = 'withdrawn';
  }
  elsif ( grep /rejected/, @$labels ) {
    $dispo = 'rejected';
  }
  elsif ( grep /paused/, @$labels ) { # otherwise, if paused present, then paused
    $dispo = 'paused';
  }
  elsif ( grep /accepted/, @$labels) {
    $dispo = 'accepted';
  }
  else {
    if (!$state || ($state eq 'OPEN')) {
      $dispo = 'submitted'; # update to review_pending, under_review
    }
    elsif ($state eq 'CLOSED') {
      $dispo = 'closed';
    }
  }
  return $dispo;
}

sub model_subm_topics {
  my ($issue) = @_;
  print STDERR "Pull $$issue{info}{repo}...";
  my $pull_repo = [split / /, "git clone $$issue{info}{repo} test"];
  my $find_paper = [split / /,"find test -name paper.md"];
  # attempt to pull repo
  unless( run $pull_repo,\$in,\$out,\$err ) {
    $log->logcarp("Could not pull repo '$$issue{info}{repo}':\n$err");
    print STDERR "fail\n";
    return;
  }
  $in=$out=$err='';
  unless( run $find_paper, \$in, \$out, \$err ) {
    $log->logcarp("paper.md not found in '$$issue{info}{repo}' master");
    rmtree("./test");
    print STDERR "fail\n";
    return;
  }
  my ($loc) = split /\n/,$out;
  unless ($loc and $loc =~ /\btest\b/) {
    $log->logcarp("find returned '$loc'");
    rmtree("./test");
    print STDERR "fail\n";
    return;
  }
  run ["cp",$loc, "./paper.md"];
  $in=$out=$err="";
  unless (run [split / /,"./topicize.r paper.md"], \$in, \$out,\$err) {
    $log->logcarp("error in topicize.r:\n$err");
    rmtree("./test");
    print STDERR "fail\n";
    return;
  }
  
  rmtree("./test");
  my @ret = split /\n/,$out;
  print STDERR "SUCCESS\n";  
  return @ret;
}
