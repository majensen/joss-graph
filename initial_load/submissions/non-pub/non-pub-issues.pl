use v5.10;
use lib 'lib';
use utf8::all;
use Carp qw/carp/;
use Net::GitHub::V4;
use Mojo::URL;
use Try::Tiny;
use Template::Tiny;
use JOSS::GHQueries;
use JOSS::WhedonSlurp;
use JSON::ize;
use strict;
use warnings;

my $tt = Template::Tiny->new();
my $wd = JOSS::WhedonSlurp->new();

open my $cred, "$ENV{HOME}/.git-credentials" or die $!;
my @cred = <$cred>;
my $ng = Net::GitHub::V4->new(
  access_token => Mojo::URL->new($cred[0])->password,
 );
my $dta;
my %issues;

open my $f, 'non-published-issue-numbers.txt' or die $!;
while (<$f>) {
  chomp;
  my $issn = $_;
  try {
    $DB::single=1;
    my $ent = {};
    $dta = $ng->query( make_qry('issue_by_number',{number => $issn}) );
    
    my $item = $dta->{data}{organization}{repository}{issue};

    $ent->{title} = $item->{title};
    $ent->{url} = $item->{url};
    $ent->{info} = $wd->parse_issue_body( $item->{body} );
    for my $l (@{$item->{labels}{nodes}}) {
      push @{$ent->{labels}}, $l->{name};
    }
    $issues{$_} = $ent;
    1;
  } catch {
    say "Query on $issn failed: $_"; 
  };
}

print J(\%issues);

sub make_qry {
  my ($qname, $args) = @_;
  my $q;
  $tt->process( \$gh_queries{$qname}, $args, \$q );
  return $q;
}
