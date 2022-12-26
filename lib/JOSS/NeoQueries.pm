package JOSS::NeoQueries;
use v5.10;
use Carp qw/carp croak/;
use Try::Tiny;
use Log::Log4perl::Tiny qw/:easy/;
use Neo4j::Driver;

my $log = get_logger();
our %neo_queries;
$ENV{NEO_URL} //= 'http://127.0.0.1:7474';

sub new {
  my ($class, $url, $user, $pass) = @_;
  my $self = {};
  $url //= $ENV{NEO_URL};
  $user //= $ENV{NEOUSER};
  $pass //= $ENV{NEOPASS};
  bless $self, $class;
  my $results;
  my $driver = $self->{_driver} = Neo4j::Driver->new($url);
  if ($user) {
    $driver->basic_auth($user, $pass);
  }
  for ($self->available_queries) {
    try {
      $results->{$_} = $driver->session->run($neo_queries{$_});
      push @{$self->{_lists}{$_}}, map {$_->get('issn')} $results->{$_}->list;
    } catch {
      $log->logcarp("query $_: session/run error - $_");
    };
  }
  return $self;
  
}

sub driver { shift->{_driver} }

sub latest_issn {
  my $self = shift;
  unless ($self->{_latest_issn}) {
    my $qry = "match (i:issue) return max(i.number) as latest";
    my $r = $self->driver->session->run($qry)->single->get('latest');
    $r || $log->logcroak("latest_issn: No latest issue returned - is this the right db?");
    $self->{_latest_issue} = $r;
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
match (s:submission {disposition:"review_pending"}) where (s)-[:has_topic]->() with s.prereview_issue_number as issn return issn
QRY
  review_pending_no_topics => <<QRY,
match (s:submission {disposition:"review_pending"}) where not (s)-[:has_topic]->() with s.prereview_issue_number as issn return issn
QRY
  under_review => <<QRY,
match (s:submission {disposition:"under_review"}) with s.review_issue_number as issn return issn
QRY
  paused_rev => <<QRY,
match (s:submission {disposition:"paused"})-[:has_review_issue]->(i:issue) return i.number as issn
QRY
  paused_prerev => <<QRY,  
match (s:submission {disposition:"paused"})-[:has_prereview_issue]->(i:issue) where not (s)-[:has_review_issue]->(:issue) return i.number as issn
QRY
 );

1;
