use v5.10;
use Neo4j::Cypher::Abstract qw/cypher ptn/;
use strict;
use warnings;

my $beta = "/Users/maj/Code/jossrev/lang-analysis/final/mlda40.beta95.tsv";

open my $fh, $beta or die $!;
my @cypher;
$_ = <$fh>;
chomp;
my @hdrs = split /\t/;
while (<$fh>) {
  my %dta;
  chomp;
  @dta{@hdrs} = split /\t/;
  my $topic = "Topic$dta{topic}";
  push @cypher, cypher->merge( ptn->N('m:mtopic', {name => $topic}) );
  push @cypher, cypher->merge( ptn->N('t:term', {value => $dta{term}}) );
  push @cypher, cypher->match( ptn->C( ptn->N('m:mtopic', {name => $topic}),
				       ptn->N('t:term', {value => $dta{term}})))
    ->merge( ptn->N('m')->R('r:has_term>')->N('t') )
    ->on_create->set(set_arg('r', {beta => 0+$dta{beta}}));
}

for (@cypher) {
  s/'([0-9.]+)'/$1/g;
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
