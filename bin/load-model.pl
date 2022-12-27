use v5.10;
use Neo4j::Cypher::Abstract qw/cypher ptn/;
use strict;
use warnings;

my $NORM_TO = 0.95;

my (@hdrs,@cypher);
while (<>) {
  chomp;
  my ($issn, @gamma) = split /\t/;
  unless (@hdrs) {
    @hdrs = map {"Topic$_"} (1..@gamma);
    for (@hdrs) {
      push @cypher, cypher->merge( ptn->N('t:mtopic', {name => $_} ) );
    }
  }
  my %topics;
  @topics{@hdrs} = @gamma;
  my $topics = renorm(\%topics);
  for my $k (keys %$topics) {
    my $q = cypher->match(ptn->C( ptn->N('s:submission')->R(":>")->N(':issue', {number => 0+$issn}), ptn->N('t:mtopic', {name => $k})))
      ->merge(ptn->N('s')->R('r:has_topic>')->N('t'))
      ->set(set_arg('r', { gamma => 0+$topics->{$k} }));
    push @cypher, $q;
  }
}

for (@cypher) {
  s/'([0-9]+)'/$1/g;
  say $_.';';
}



sub set_arg {
  my ($nd,$hash) = @_;
  my $ret = {};
  for (keys %$hash) {
    $ret->{"$nd\.$_"} = $hash->{$_} if defined $hash->{$_};
  }
  return $ret;
}

sub renorm {
  my ($thash) = @_;
  my @desckeys = sort { $thash->{$b} <=> $thash->{$a} } keys %$thash;
  my $cum = 0;
  my @normkeys;
  for my $k (@desckeys) {
    $cum+=$thash->{$k};
    push @normkeys, $k;
    last if $cum >= $NORM_TO;
  }
  my $ret;
  for (@normkeys) {
    $ret->{$_} = $thash->{$_}/$cum;
  }
  return $ret;
}
