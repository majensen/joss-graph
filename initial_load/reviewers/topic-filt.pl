use v5.10;
use List::MoreUtils;
use List::Util;
use strict;
use warnings;

# alg:
# 1. one word topic strings are topics
# 2. almost all 2-word topic strings are single topics (a couple to break into single-word topics)
# 3. many 3-word topic strings are single topics
# filter the remaining topic strings using 2., then 1., and examine what remains.


open my $f, "norm-topic-strings.txt" or die $!;
my (@t, %dist);

while (<$f>) {
  chomp;
  push @t, $_;
  my @a = split /\s+/;
  push @{$dist{scalar @a}}, $_;
}

1;
my $single = delete $dist{1};
my $double = delete $dist{2};
my $triple = delete $dist{3};

my @longer;
for my $n (sort {$a <=> $b} keys %dist) {
  push @longer, @{$dist{$n}}
}

my %found;

my $upd=1;
while ($upd) {
  $upd=0;
  for my $term ( sort @$triple ) {
    for (@longer) {
      if (/\b$term\b/) {
	$upd=1;
	$found{3}++;
	s/\b$term\b//; # remove
	s/\s+/ /g;
	s/^\s+//;
	s/\s+$//;
      }
    }
  }
}

$upd=1;
while ($upd) {
  $upd=0;
  for my $term ( sort @$double ) {
    for (@longer) {
      if (/\b$term\b/) {
	$upd=1;
	$found{2}++;
	s/\b$term\b//; # remove
	s/\s+/ /g;
	s/^\s+//;
	s/\s+$//;
      }
    }
  }
  1;
}

1;
