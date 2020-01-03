# create cypher statements
# reviews will have a strawman joss_doi
# lone prereviews will have a null joss_doi

use v5.10;
use Try::Tiny;
use Log::Log4perl::Tiny qw/:easy/;
use JSON::ize;
use Set::Scalar;
use Neo4j::Cypher::Abstract qw/cypher ptn/;
use strict;
use warnings;

my $log = get_logger();

my $issues;
my $fn = $ARGV[0];
if ($fn) {
  try {
    $issues = J($fn);
  } catch {
    $log->logcroak("Problem loading input json '$fn': $_");
  };
}
else {
  local $/;
  $_ = <>;
  parsej;
  $issues = J();
  $log->logcroak("Problem loading input json from STDIN") unless $issues;
}

my $iss = Set::Scalar->new( sort {$a<=>$b} keys %$issues );
my $revs = Set::Scalar->new( grep { $issues->{$_}{title} and $issues->{$_}{title} =~ /^\[REVIEW\]/ } $iss->members );
my $m_revs = Set::Scalar->new( grep { $issues->{$_}{prerev} } $revs->members );
my $m_prerevs = Set::Scalar->new( map { $issues->{$_}{prerev} } $m_revs->members );
my $prerevs = Set::Scalar->new( grep { $issues->{$_}{title} and $issues->{$_}{title} =~ /^\[PRE.REVIEW\]/ } $iss->members );
my $lone_prerevs = $prerevs->difference($m_prerevs);
my $lone_revs = $revs->difference($m_revs);

# other issues are cruft.

my @cypher;

# matched rev/prerevs
for my $issn (sort {$a<=>$b} $m_revs->members) {
  my $subm = $issues->{$issn};
  my $url_stem = $subm->{url};
  $url_stem =~ s/[0-9]+$//;
  unless ($subm) {
    $log->logcarp("No review with issue number $issn");
    next;
  }
  my $iss_spec = {
    joss_doi => sprintf( "10.21105/joss.%05d", $issn),
    review_issue => $subm->{url},
    prereview_issue => $url_stem.$subm->{prerev},
    disposition => ($subm->{paper} ? 'published' : $subm->{disposition}),
  };
  create_stmts($subm, $iss_spec);
}

for my $issn (sort {$a<=>$b} $lone_revs->members) {
  my $subm = $issues->{$issn};
  unless ($subm) {
    $log->logcarp("No review with issue number $issn");
    next;
  }
  my $iss_spec = {
    joss_doi => sprintf( "10.21105/joss.%05d", $issn),
    review_issue => $subm->{url},
    disposition => ($subm->{disposition} eq 'submitted' ? 'under_review' : $subm->{disposition}),
  };
  create_stmts($subm, $iss_spec);
}

for my $issn (sort {$a<=>$b} $lone_prerevs->members) {
  my $subm = $issues->{$issn};
  unless ($subm) {
    carp $log->logcarp("No review with issue number $issn");
    next;
  }
  my $iss_spec = {
    prereview_issue => $subm->{url},
    disposition => ($subm->{disposition} eq 'submitted' ? 'review_pending' : $subm->{disposition}),
  };
  create_stmts($subm, $iss_spec);
}

say $_.';' for @cypher;

1;

sub create_stmts {
  my ($subm, $issue_spec) = @_;
  # submission spec
  my $s_spec = {
    title => $subm->{title},
    %$issue_spec,
    repository => $subm->{info}{repo},
  };
  # submitter spec
  my $sa_spec = {
    handle => $subm->{info}{author}{handle},
    real_name => $subm->{info}{author}{name},
    $subm->{info}{author}{orcid} ? (orcid => $subm->{info}{author}{orcid}) : (),
  };
  # editor spec
  my $ed_spec = { handle => $subm->{info}{editor} };
  # reviewer specs
  my @rev_specs;
  for my $r (@{$subm->{info}{reviewers}}) {
    push @rev_specs, {
      handle => $r,
     };
  }
  # paper spec
  my $p_spec;
  if (my $paper = $subm->{paper}) {
    $p_spec = {
      title => $paper->{title},
      joss_doi => $paper->{joss_doi},
      archive_doi => $paper->{archive_doi},
      published_date => $paper->{published_date},
      volume => 0+$paper->{volume},
      issue => 0+$paper->{issue},
      url => $paper->{url},
    };    
  }

  # create cypher stmts
  # submission
  my $mrg_spec = ($s_spec->{joss_doi} ? {joss_doi => $s_spec->{joss_doi}} :
		    { prereview_issue => $s_spec->{prereview_issue}});
  my $upd_spec = {
    $s_spec->{review_issue} ? (review_issue => $s_spec->{review_issue}) : (),
    $s_spec->{prereview_issue} ? (prereview_issue => $s_spec->{prereview_issue}) : (),
    $s_spec->{disposition} ? (disposition => $s_spec->{disposition}) : (),        
  };
  push @cypher, cypher->merge(ptn->N('s:submission', $mrg_spec))
    ->on_create->set(set_arg('s', $s_spec))
    ->on_match->set(set_arg('s', $upd_spec));

  #person
  # editor
  if ($ed_spec->{handle}) {
    push @cypher, cypher->merge(ptn->N('e:person', { handle => $ed_spec->{handle} }));
  }
  # submitter
  my ($mrg_sa) = ($sa_spec->{handle} ? { handle => $sa_spec->{handle} } : { orcid => $sa_spec->{orcid} } );
  if (defined [values %$mrg_sa]->[0]) {
    push @cypher, cypher->merge(ptn->N('b:person', $mrg_sa))
      ->on_create->set(set_arg('b',$sa_spec));
  }
  else {
    1;
  }
  # reviewers
  for my $r_spec (@rev_specs) {
    push @cypher, cypher->merge(ptn->N('r:person', { handle => $r_spec->{handle} }));
  }

  # assignment
  # editor <- assign -> submission
  if ($ed_spec->{handle}) {
    push @cypher, cypher->match(ptn->C(ptn->N('e:person',{handle => $ed_spec->{handle}}),
				       ptn->N('s:submission', $mrg_spec)))
      ->merge(ptn->N('e')->R('<:assigned_to')->N('a:assignment', {role => 'editor'})
	       ->R(':assigned_for>')->N('s'));
  }

  # submitter <- assign(as submitter) -> submission
  if (defined [values %$mrg_sa]->[0]) {  
    push @cypher, cypher->match(ptn->C(ptn->N('b:person', $mrg_sa),
				       ptn->N('s:submission', $mrg_spec)))
      ->merge(ptn->N('b')->R('<:assigned_to')->N('a:assignment', {role => 'submitter'})
	       ->R(':assigned_for>')->N('s'));
    
    # submitter <- assign(as author) -> submission
    push @cypher, cypher->match(ptn->C(ptn->N('b:person', $mrg_sa),
				       ptn->N('s:submission', $mrg_spec)))
      ->merge(ptn->N('b')->R('<:assigned_to')->N('a:assignment', {role => 'author'})
	       ->R(':assigned_for>')->N('s'));
  }
  # reviewer <- assign -> submission
  for my $rev_spec (@rev_specs) {
    push @cypher, cypher->match(ptn->C(ptn->N('r:person',{handle => $rev_spec->{handle}}),
				ptn->N('s:submission', $mrg_spec)))
      ->merge(ptn->N('r')->R('<:assigned_to')->N('a:assignment', {role => 'reviewer'})
	       ->R(':assigned_for>')->N('s'));
  }

  # paper node if applicable
  if ($p_spec) {
    my @other_au_specs;
    for my $other (@{$subm->{paper}{authors}}) {
      next if ($other->{orcid} && ($other->{orcid} eq $subm->{info}{author}{orcid}));
      push @other_au_specs,
	{
	  real_name => join(" ", @{$other}{qw/first_name last_name/}),
	  $other->{orcid} ? (orcid => $other->{orcid}) : (),
	};
    }
    push @cypher, cypher->merge(ptn->N('p:paper', { joss_doi => $p_spec->{joss_doi} }))
      ->on_create->set(set_arg('p',$p_spec));
    for my $oth_spec (@other_au_specs) {
      my $mrg_o = ($oth_spec->{orcid} ? {orcid => $oth_spec->{orcid}} : {real_name => $oth_spec->{real_name}});
      push @cypher, cypher->merge(ptn->N('o:person', $mrg_o))
	->on_create->set(set_arg('o',$oth_spec));
    }

    # paper -> submission
    
    push @cypher, cypher->match( ptn->C(ptn->N('p:paper', {joss_doi => $p_spec->{joss_doi}}),
					ptn->N('s:submission', {joss_doi => $s_spec->{joss_doi}})) )
      ->merge( ptn->N('p')->R(':from_submission>')->N('s') );

  }
  
  return 1;
}


sub set_arg {
  my ($nd,$hash) = @_;
  my $ret = {};
  for (keys %$hash) {
    $ret->{"$nd\.$_"} = $hash->{$_} if defined $hash->{$_};
  }
  return $ret;
}
