package JOSS::NeoQueries;
use v5.10;
use Carp qw/carp croak/;
use Try::Tiny;
use Log::Log4perl::Tiny qw/:easy/;
use DBI;

my $log = get_logger();
our %neo_queries;
$ENV{NEODSN} //= 'dbi:Neo4p:db=http://127.0.0.1:7474';
$ENV{NEOUSER}='neo4j';
$ENV{NEOPASS}='j4oen';
$dbh->{RaiseError} = 1;

sub new {
  my ($class, $dsn, $user, $pass) = @_;
  my $self = {};
  $dsn //= $ENV{NEODSN};
  $user //= $ENV{NEOUSER};
  $pass //= $ENV{NEOPASS};
  bless $self, $class;
  my $sth;
  my $dbh = $self->{_dbh} = DBI->connect($dsn,$user,$pass);
  for (keys %neo_queries) {
    try {
      $sth->{$_} = $dbh->prepare($neo_queries{$_});
    } catch {
      $log->logcarp("query $_: prepare error - $_");
    };
    try {
      $sth->{$_}->execute;
      while (my $r = $sth->{$_}->fetch) {
	push @{$self->{_lists}{$_}}, $r->[0];
      }
    } catch {
      $log->logcarp("query $_: execute error - $_");
    };
  }
  return $self;
  
}

sub dbh { shift->{_dbh} }

sub latest_issn {
  my $self = shift;
  unless ($self->{_latest_issn}) {
    my $qry = <<QRY;
match (s:submission) with [toInteger(replace(s.prereview_issue, "https://github.com/openjournals/joss-reviews/issues/","")), toInteger(replace(s.review_issue, "https://github.com/openjournals/joss-reviews/issues/",""))] as l with l unwind l as ll with ll where ll is not null return  max(ll);
QRY
    my $sth = $self->dbh->prepare($qry);
    $sth->execute;
    my $r = $sth->fetch;
    $r || $log->logcroak("latest_issn: No latest issue returned - is this the right db?");
    $self->{_latest_issue} = $r->[0];
  }
  return $self->{_latest_issue};
}

sub available_queries { sort keys %neo_queries }

sub AUTOLOAD {
  my $self = shift;
  my $method = $AUTOLOAD;
  $method =~ s/.*:://;
  return if $method eq 'DESTROY';
  unless (grep /^$method/, keys %neo_queries) {
    $log->logcroak("Method '$method' not defined in package ".__PACKAGE__);
  }
  return @{$self->{_lists}{$method}};
}

sub DESTROY { }

%neo_queries = (
  review_pending_has_topics => <<QRY,
match (s:submission {disposition:"review_pending"}) where (s)-[:has_topic]->() with toInteger(replace(s.prereview_issue, "https://github.com/openjournals/joss-reviews/issues/","")) as issn return issn
QRY
  review_pending_no_topics => <<QRY,
match (s:submission {disposition:"review_pending"}) where not (s)-[:has_topic]->() with toInteger(replace(s.prereview_issue, "https://github.com/openjournals/joss-reviews/issues/","")) as issn return issn
QRY
  under_review => <<QRY,
match (s:submission {disposition:"under_review"}) with toInteger(replace(s.review_issue, "https://github.com/openjournals/joss-reviews/issues/","")) as issn return issn
QRY
  paused_rev => <<QRY,
match (s:submission {disposition:"paused"}) where exists(s.review_issue) with toInteger(replace(s.review_issue, "https://github.com/openjournals/joss-reviews/issues/","")) as issn return issn
QRY
  paused_prerev => <<QRY,  
match (s:submission {disposition:"paused"}) where not exists(s.review_issue) and exists(s.prereview_issue) with toInteger(replace(s.prereview_issue, "https://github.com/openjournals/joss-reviews/issues/","")) as issn return issn
QRY
 );

1;
