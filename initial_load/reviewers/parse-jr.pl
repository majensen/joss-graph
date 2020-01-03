use v5.10;
use strict;
use warnings;
use Neo4j::Cypher::Abstract qw/cypher ptn/;

# for now, put normalized reviewer topic strings in a topic node with full-text indexed name
# work on the topic filtering; later create real topic nodes.

my @hdrs = qw/
	       handle
	       pref_lang
	       other_lang
	       affiliation
	       email
	       topic
	       active
	       all_time
	       last_year
	       last_quarter
	     /;
my $persons = {};
my $fn = shift();
die "Problem with file '$fn': $!" unless (-e $fn);

open my $fh, "<", $fn or die "Problem with '$fn': $!";

my %lfilt;
open my $xlt, "<lang-filt.txt" or die "lang-filt.txt: $!";
while (<$xlt>) {
  chomp;
  my @a = /'([^']+)'/g;
  $lfilt{$a[0]} = $a[1] // 1;
}

while (<$fh>) {
  chomp;
  my @dta = split /\t/;
  my %data;
  @data{@hdrs} = @dta;
  if ($persons->{$data{handle}}) {
    warn "At $.: $data{handle} is duplicated";
  }
  $persons->{$data{handle}} = \%data;
}

my (%lang, %topic);

for my $nm (keys %$persons) {
  for my $key (qw/pref_lang other_lang/) {
    my $l = $persons->{$nm}{$key};
    $l = lc $l;
    $l =~ s/\([^)]+\)//g;
    for my $tok (split /(?: *, *)|\n+|(?: *\/ *)|(?: and )|(?: *; *)/, $l) {
      $tok =~ s/^\s+//;
      $tok =~ s/\.?\s+$//;
      $tok =~ s/'//g;
      $tok =~ s/`//g;
      if ($lfilt{$tok}) {
	next if ($lfilt{$tok} eq '1');
	$tok = $lfilt{$tok}
      }
      for my $t (split /\s+/,$tok) {
	push @{$lang{$t}{$key}},$nm;
      }
    }
  }
  my $t = $persons->{$nm}{topic};
  $t = lc $t;
  $t =~ s/\([^)]+\)//g;
  for my $tok (split /(?: *, *)|\n/, $t) {
    $tok =~ s/^\s*//;
    $tok =~ s/\s*$//;
    push @{$topic{$tok}}, $nm
  }
}

1;

for my $lang (keys %lang) {
  my $spec = ptn->N("l:language",{ name => $lang });
  say cypher->merge($spec).";";
}
say cypher->create_index( language => 'name' ).";";

for my $topic (keys %topic) {
  my $spec = ptn->N("t:topic",{ content  => $topic });
  say cypher->merge($spec).";";  
}

say 'CALL db.index.fulltext.createNodeIndex("topicIndex",["topic"], ["content"]);';

for my $k (keys %$persons) {
  my $data = $persons->{$k};
  my $spec = ptn->N("n:person",
		     { handle => $data->{handle},
		       $data->{email} ? (email => $data->{email}) : (),
		       $data->{affiliation} ? (affiliation => $data->{affiliation}):() });
  if ($data->{active} || $data->{all_time} || $data->{last_year} || $data->{last_quarter}) {
    $spec->R(':has_snapshot>')->N('s:rev_snapshot',
				 { updated_date => '2019-12-01',
				   active => 0+($data->{active} // 0),
				   all_time => 0+($data->{all_time} // 0),
 				   last_year => 0+($data->{last_year} // 0),
 				   last_quarter => 0+($data->{last_quarter} // 0),
				 })
  }
  my $stmt = cypher->merge($spec)->as_string;
  $stmt =~ s/\'([0-9]+)\'/$1/g;
  say $stmt.";";
}

say cypher->create_index( person => 'handle' ).";";

for my $lang (keys %lang) {
  my ($spec,$match);
  for my $nm ( @{$lang{$lang}{pref_lang}} ) {
    $match = ptn->C( ptn->N('p:person',{ handle  => $nm }), ptn->N('l:language',{ name => $lang }));
    $spec = ptn->N('p')->R(':has_preferred_language>')->N('l');
    say cypher->match($match)->merge($spec).";";
  }
  for my $nm ( @{$lang{$lang}{other_lang}} ) {
    $match = ptn->C( ptn->N('p:person',{ handle => $nm }), ptn->N('l:language',{ name => $lang }));
    $spec = ptn->N('p')->R(':has_additional_language>')->N('l');
    say cypher->match($match)->merge($spec).";";
  }
}

for my $content (keys %topic) {
  my ($spec,$match);
  for my $nm ( @{$topic{$content}} ) {
    $match = ptn->C( ptn->N('p:person',{ handle => $nm }), ptn->N('t:topic',{ content => $content }));
    $spec = ptn->N('p')->R(':prefers_topic>')->N('t');
    say cypher->match($match)->merge($spec).";";
  }
}

