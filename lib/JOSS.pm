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
our @EXPORT_OK = qw/CHUNK/;
# get_last_issue_num get_last_issues get_issue_by_num get_paper_text model_subm_topics find_prerev_for_rev find_xml_for_accepted latest_issn $ng $nq $wd/;
our $AUTOLOAD;

sub CHUNK { 50 }

sub new {
  my ($class, $neo_url) = @_;
  my ($self) = {};
  bless $self, $class;
  $self->{_nq} = JOSS::NeoQueries->new($neo_url);
  $self->{_wd} = JOSS::WhedonSlurp->new();
  my $pw = $ENV{GHCRED};
  unless ($pw) {
    if ( -e "$ENV{HOME}/.git-credentials" ) {
      open my $cred, "$ENV{HOME}/.git-credentials" or get_logger()->logdie("Problem with .git-credentials: $!");
      my @cred = <$cred>;
      $pw = Mojo::URL->new($cred[0])->password;
    }
  }
  $self->{_ng} = Net::GitHub::V4->new(
    access_token => $pw,
   );
  return $self;
}

sub get_last_issues {
  my ($self, $nr) = @_;
  my $dta;
  my $cursor;
  my %issues;
  my $log = get_logger();
  while ($nr > 0) {
    my $c = ($nr < CHUNK ? $nr : CHUNK);
    $log->debug("Query Github for $c issues");
    try {
      $dta = $self->{_ng}->query( make_qry('last_n_issues',
				  { chunk => $c,
				    cursor => $cursor}));
      if (!$dta || ! scalar(keys %$dta)) {
	$log->logcroak("last_n_issues query returned no data");
      }
      elsif ($$dta{message}) {
	$log->logcroak("last_n_issues query failed with msg: '$$dta{message}'");
      }
    } catch {
      $log->logcarp("last_n_issues query failed: $_");
      undef $dta;
    };
    unless ($dta) {
      return;
    }
    for my $issue ( @{$dta->{data}{organization}{repository}{issues}{nodes}} ) {
      $issues{$issue->{number}} = $self->parse_issue($issue);
    }
    $cursor = $dta->{data}{organization}{repository}{issues}{pageInfo}{startCursor};
    print STDERR ".";
    $nr -= $c;
  }
  $log->debug("Finished Github query for issues");
  print STDERR "done\n";
  return \%issues;
}

sub get_issue_by_num {
  my ($self, $num) = @_;
  my $dta;
  my $log = get_logger();
  $log->debug("Query Github for issue number $num");
  try {
    $dta = $self->{_ng}->query( make_qry('issue_by_number', { number => $num }) );
    if ($$dta{message}) {
	$log->logcroak("last_n_issues query failed with msg: '$$dta{message}'");
	return;
      }
  } catch {
    $log->logcarp("issue_by_number query failed: $_");
    undef $dta;
  };
  if ($dta) {
    $log->debug("Finished Github query for issue number $num");
    my $issue = $dta->{data}{organization}{repository}{issue};
    return unless $issue;
    return $self->parse_issue($issue);
  }
  else {
    return;
  }
}

sub get_last_issue_num {
  my $self = shift;
  my $dta;
  my $log = get_logger();
  $log->debug("Query Github for last issue number");
  try {
    $dta = $self->{_ng}->query( make_qry('last_issue_number') );
    if ($$dta{message}) {
      $log->logcroak("last_n_issues query failed with msg: '$$dta{message}'");
      return;
    }
  } catch {
    $log->logcarp("last_issue_number query failed: $_");
    undef $dta
  };
  if ($dta) {
    $log->debug("Finished Github query for last issue number");
    return 0+${$dta->{data}{organization}{repository}{issues}{nodes}}[0]->{number};
  }
  else {
    return;
  }
}

sub find_prerev_for_rev {
  my ($self, $issn) = @_;
  my $dta;
  my $log = get_logger();
  $log->debug("Query Github to find prereview issue for review issue $issn");
  try {
    $dta = $self->{_ng}->query( make_qry('prereview_issue_by_review_issue', { number => $issn } ) );
    if ($$dta{message}) {
      $log->logcroak("last_n_issues query failed with msg: '$$dta{message}'");
      return;
    }
  } catch {
    $log->logcarp("prereview_issue_by_review_issue: query on $issn failed: $_");
    undef $dta;
  };
  if ($dta) {
    $log->debug("Finished Github query for prereview issue");
    my $nodes = $dta->{data}{organization}{repository}{issue}{timelineItems}{edges};
    for (@$nodes) {
      my $src = $_->{node}{source};
      if ($src->{author}{login} =~ /whedon|editorialbot/ and $src->{title} =~ /^\s*\[PRE\s*REVIEW\]/) {
	return 0+$src->{number};
      }
    }
  }
  else {
    $log->logcarp("No pre-review issue found for $issn");
    return;
  }
}

sub find_xml_for_accepted {
  my ($self, $issn) = @_;
  my $ua = Mojo::UserAgent->new();
  my $dta;
  my $log = get_logger();
  $log->debug("Query Github to find publication comment for issue $issn");
  try {
    $dta = $self->{_ng}->query( make_qry('last_n_comments_of_issue', { number => $issn, chunk => 15 } ) );
    if ($$dta{message}) {
      $log->logcroak("last_n_issues query failed with msg: '$$dta{message}'");
      return;
    }
  } catch {
    $log->logcarp("last_n_comments_of_issue: query on $issn failed: $_");
    undef $dta;
  };
  if ($dta) {
    $log->debug("Finished Github query for publication comment");
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
  else {
    return;
  }
  
}

sub get_paper_text {
  my ($self, $issue) = @_;
  my ($in, $out, $err);
  my $log = get_logger();
  $log->debug("Attempt to get paper text for issue $$issue{number}");
  $log->info("Sparse, shallow pull $$issue{info}{repo}");
  my $branch = $issue->{info}{branch} ? "--branch $$issue{info}{branch}" : "";
  my $pull_repo = [split / +/, "git clone --sparse --depth 1 $branch $$issue{info}{repo} josstest"];
  my $add_paper_dir = [split / +/, "git sparse-checkout add paper"];
  my $find_paper = [split / /,"find josstest -name paper.md"];
  my $disable_sparse = [split / /,"git sparse-checkout disable"];
  # attempt to pull repo
  $in = "\n\n"; # get past logins
  unless( run $pull_repo,\$in,\$out,\$err ) {
    $log->logcarp("Could not pull repo '$$issue{info}{repo}':\n$err");
    print STDERR "fail\n";
    return;
  }
  run( $add_paper_dir, init => sub { chdir "josstest" or $log->logcarp($!); } );
  $in=$out=$err='';
  unless( run $find_paper, \$in, \$out, \$err ) {
    $log->logcarp("paper.md not found in '$$issue{info}{repo}' main branch");
    rmtree("./josstest");
    print STDERR "fail\n";
    return;
  }
  
  my ($loc) = split /\n/,$out;
  unless ($loc and $loc =~ /\bjosstest\b/) {
    $in=$out=$err='';
    run( $disable_sparse, init => sub { chdir "josstest" or $log->logcarp($!); } );
    run ($find_paper, \$in, \$out, \$err);
    ($loc) = split /\n/,$out;
  }
  unless ($loc and $loc =~ /\bjosstest\b/) {      
    $log->logcarp("paper.md not found in repo as pulled");
    rmtree("./josstest");
    print STDERR "fail\n";
    return;
  }
  undef $/;
  open my ($ppr), $loc;
  try {
    $issue->{paper_text} = <$ppr>;
  } catch {
    $log->logcarp("Failed to read paper.md on $issue->{info}{repo}: $_");
  };
  rmtree("./josstest");
  return 1;
}

sub model_subm_topics {
  my ($self, $issue) = @_;
  my ($in, $out, $err);
  my $log = get_logger();
  unless ($issue->{paper_text}) {
    $log->logcarp("No paper text for issue $issue->{number}");
    return;
  }
  $log->info("Model paper topics for issue $issue->{number}");
  my ($fh, $f) = tempfile();
  binmode $fh, ":utf8";
  print $fh $issue->{paper_text};
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
  my ($self, $issue) = @_;
  my $log = get_logger();
  $log->debug("Parsing issue $issue->{number}");
  $self->{_wd}->parse_issue_body( $issue );
  my @lbls;
  for my $l (@{$issue->{labels}{nodes}}) {
    push @lbls, $l->{name};
  }
  $issue->{label_names} = \@lbls;
  $issue->{disposition} = dispo([map {$_->{name}} @{$issue->{labels}{nodes}}],$issue->{state});
  if ($issue->{title} =~ /^\s*\[REVIEW/) {
    my $issn = $issue->{number};
    my $prn = $self->find_prerev_for_rev($issn);
    $issue->{prerev} = $prn if $prn;
    if ($issue->{disposition} eq 'accepted') { # get publication info
      my $xrf = $self->find_xml_for_accepted($issn);
      if ($xrf) {
	$issue->{disposition} = 'published';
	my $p = {};
	$$p{authors} = $xrf->get_authors;
	$$p{published_date} = $xrf->get_pubdate;
	$$p{title} = $xrf->get_title;
	$$p{review_issue} = $xrf->get_review_issue;
	@{$p}{qw/volume issue/} = @{$xrf->get_vol_issue}{qw/volume issue/};
	@{$p}{qw/joss_doi archive_doi url/} = @{$xrf->get_dois}{qw/jdoi adoi url/};
	$issue->{paper} = $p;
      }
      else {
	$log->info("Issue $issn - accepted but crossref.xml not found");
      }
    }
  }
  $log->debug("Issue $$issue{number} parsed");
  return $issue;
}

# local
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

sub AUTOLOAD {
  my $self = shift;
  my $method = $AUTOLOAD;
  $method =~ s/.*:://;
  return if $method eq 'DESTROY';
  return $self->{_nq}->$method;
}

1;
