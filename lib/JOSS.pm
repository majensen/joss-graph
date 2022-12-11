package JOSS;
use v5.10;
use base Exporter;
use utf8::all;
use JOSS::GHQueries;
use JOSS::WhedonSlurp;
use JOSS::Crossref;
use JOSS::NeoQueries;
use Net::GitHub::V4;
use Mojo::UserAgent;
use IPC::Run qw/run timeout/;
use File::Path qw/rmtree/;
use File::Temp qw/tempfile/;
use Log::Log4perl::Tiny qw/:easy build_channels/;
use Try::Tiny;
use strict;
use warnings;

our $VERSION = '0.100';
our @EXPORT_OK = qw/CHUNK get_last_issue_num get_last_issues get_issue_by_num get_paper_text model_subm_topics find_prerev_for_rev find_xml_for_accepted latest_issn $ng $nq $wd/;

sub CHUNK { 50 }
our $nq = JOSS::NeoQueries->new();
our $wd = JOSS::WhedonSlurp->new();
my $pw = $ENV{GHCRED};
unless ($pw) {
  if ( -e "$ENV{HOME}/.git-credentials" ) {
    open my $cred, "$ENV{HOME}/.git-credentials" or get_logger()->logdie("Problem with .git-credentials: $!");
    my @cred = <$cred>;
    $pw = Mojo::URL->new($cred[0])->password;
  }
}
our $ng = Net::GitHub::V4->new(
  access_token => $pw,
 );

sub latest_issn {
  $nq->latest_issn;
}

sub get_last_issues {
  my ($nr) = @_;
  my $dta;
  my $cursor;
  my %issues;
  my $log = get_logger();
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
    for my $issue ( @{$dta->{data}{organization}{repository}{issues}{nodes}} ) {
      $issues{$issue->{number}} = parse_issue($issue);
    }
    $cursor = $dta->{data}{organization}{repository}{issues}{pageInfo}{startCursor};
    print STDERR ".";
    $nr -= $c;
  }
  print STDERR "done\n";
  return \%issues;
}

sub get_issue_by_num {
  my ($num) = @_;
  my $dta;
  my $log = get_logger();
  try {
    $dta = $ng->query( make_qry('issue_by_number', { number => $num }) );
  } catch {
    $log->logcarp("issue_by_number query failed: $_");
    return;
  };
  my $issue = $dta->{data}{organization}{repository}{issue};
  return parse_issue($issue);
}

sub get_last_issue_num {
  my $dta;
  my $log = get_logger();
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
  my $dta;
  my $log = get_logger();
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
  my $ua = Mojo::UserAgent->new();
  my $dta;
  my $log = get_logger();
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

sub get_paper_text {
  my ($issue) = @_;
  my ($in, $out, $err);
  my $log = get_logger();
  $log->info("Sparse, shallow pull $$issue{info}{repo}");
  $DB::single=1;
  my $branch = $issue->{info}{branch} ? "--branch $$issue{info}{branch}" : "";
  my $pull_repo = [split / +/, "git clone --sparse --depth 1 $branch $$issue{info}{repo} test"];
  my $add_paper_dir = [split / +/, "git sparse-checkout add paper"];
  my $find_paper = [split / /,"find test -name paper.md"];
  # attempt to pull repo
  unless( run $pull_repo,\$in,\$out,\$err ) {
    $log->logcarp("Could not pull repo '$$issue{info}{repo}':\n$err");
    print STDERR "fail\n";
    return;
  }
  run( $add_paper_dir, init => sub { chdir "test" or $log->logcarp($!); } );
  $in=$out=$err='';
  unless( run $find_paper, \$in, \$out, \$err ) {
    $log->logcarp("paper.md not found in '$$issue{info}{repo}' main branch");
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
  undef $/;
  open my ($ppr), $loc;
  $issue->{paper_text} = <$ppr>;
  rmtree("./test");
  return 1;
}

sub model_subm_topics {
  my ($issue) = @_;
  my ($in, $out, $err);
  my $log = get_logger();
  unless ($issue->{paper_text}) {
    $log->logcarp("No paper text for issue $issue->{number}");
    return;
  }
  $log->info("Model paper topics for issue $issue->{number}");
  my ($f, $fh) = tempfile();
  print $fh, $issue->{paper_text};
  $fh->flush;
  unless (run [split / /,"./topicize.r $f"], \$in, \$out,\$err) {
    $log->logcarp("error in topicize.r:\n$err");
    print STDERR "fail\n";
    return;
  }
  my @ret = split /\n/,$out;
  $log->info("Paper topics for issue $issue->{number} successfully modeled");
  return @ret;
}

sub parse_issue {
  my ($issue) = @_;
  my $log = get_logger();
  $log->info("Parsing issue $issue->{number}");
  $wd->parse_issue_body( $issue );
  my @lbls;
  for my $l (@{$issue->{labels}{nodes}}) {
    push @lbls, $l->{name};
  }
  $issue->{label_names} = \@lbls;
  $issue->{disposition} = dispo([map {$_->{name}} @{$issue->{labels}{nodes}}],$issue->{state});
  return $issue;
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

1;
