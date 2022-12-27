package JOSS::Recommender;
use v5.10;
use Neo4j::Driver;
use Set::Scalar;
use Log::Log4perl::Tiny qw/:easy/;

my $log = get_logger();
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
  return $self;
}

sub driver { shift->{_driver} }

sub reviewers_for_submission {
  my ($self, $issn, $TOP) = @_;
  $TOP //= 20;
  my $res = $self->driver->session->run(
    'match (s:submission)-->(i:issue {number:$issn}) with s match (s)-[r:has_topic]->(m:mtopic) return m.name as topic, r.gamma as gamma',
    { issn => $issn }
   );
  my %gammas;
  unless (scalar @{$res->list}) {
    $log->logcarp("No model information found for submission with issue $issn");
    return;
  }
  @gammas{ map { $_->get('topic') } $res->list } =
    map {$_->get('gamma')} $res->list;
  my $topics = '['.join(',', map { "'$_'" } keys %gammas).']';
  my $qry =     "with $topics as topics ".
      'match (p:person)-[r:has_portfolio_topic]->(m:mtopic) '.
      'where m.name in topics and exists(p.handle) '.
      ' and not (p)<--(:assignment {role:"editor"}) '.
      'with p, collect(r.score) as scores, collect(m.name) as ptopics '.
      'return p.handle as hdl, scores, ptopics';

  $res = $self->driver->session->run($qry);
  my %people;
  for my $rec ($res->list) {
    my %portf;
    @portf{@{$rec->get('ptopics')}} = @{$rec->get('scores')};
    my $suit = 0;
    for my $topic (keys %gammas) {
      $suit += $gammas{$topic} * ($portf{$topic} // 0);
    }
    $people{$rec->get('hdl')} = $suit;
  }
  @people = sort { $people{$b} <=> $people{$a} } keys %people;
  @ret = map { [$_, $people{$_}] } @people[0..$TOP-1];
  return @ret;
} 

