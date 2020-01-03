# merge paper data and author data,
# create cypher statements
use v5.10;
use Carp qw/carp croak/;
use JSON::ize;
use Neo4j::Cypher::Abstract qw/cypher ptn/;
use strict;
use warnings;


my $papers = J('papers.json');
my $subs = J('pub-subm.json');
my @cypher;

for my $issn (sort { $a <=> $b } keys %$papers) {
  my $subm = $subs->{$issn};
  unless ($subm) {
    carp "No submission entry for $issn";
    next;
  }
  # create paper node
  # create person nodes (merge and add props if person with handle exists)
  # create assignment nodes with correct roles and links to persons and papers
  my $paper = $papers->{$issn};
  my $p_spec = {
    title => $paper->{title},
    joss_doi => $paper->{joss_doi},
    archive_doi => $paper->{archive_doi},
    published_date => $paper->{published_date},
    volume => 0+$paper->{volume},
    issue => 0+$paper->{issue},
    url => $paper->{url},
  };
  my $s_spec = {
    title => $paper->{title},
    joss_doi => $paper->{joss_doi},
    repository => $subm->{repo},
    review_issue => $paper->{review_issue},
    disposition => 'published',
  };

  # authors:
  # identify submitting author in crossref author list:
  my $sauth;
  if (my $orc = $subm->{author}{orcid}) {
    ($sauth) = grep { $_->{orcid} && ($orc eq $_->{orcid}) } @{$paper->{authors}};
  }
  if (!$sauth) {
    $subm->{author}{name} =~ /(\S+)\s*$/; # ~last name
    my $ln = $1;
    ($sauth) = grep { my $a = $$_{first_name}.$$_{last_name}; $a =~ /$ln/i} @{$paper->{authors}};
  }
  carp "Could not id submitting author in crossref authors for issue $issn" unless $sauth;

  my $sa_spec = {
    real_name => join(" ", @{$sauth}{qw/first_name last_name/}),
    handle => $subm->{author}{handle},
    ($subm->{author}{orcid} || $sauth->{orcid} ) ? (orcid => $subm->{author}{orcid} // $sauth->{orcid} ) : ()
   };

  my @other_au_specs;
  for my $other (@{$paper->{authors}}) {
    next if ($other->{orcid} && ($other->{orcid} eq $subm->{author}{orcid}));
    push @other_au_specs,
      {
	real_name => join(" ", @{$other}{qw/first_name last_name/}),
	$other->{orcid} ? (orcid => $other->{orcid}) : (),
      };
  }

  my $ed_spec = {
    handle => $subm->{editor},
  };

  my @rev_specs;
  for my $r (@{$subm->{reviewers}}) {
    push @rev_specs, {
      handle => $r,
     };
  }

  # create cypher statements
  # paper
  $DB::single=1;

  push @cypher, cypher->merge(ptn->N('p:paper', { joss_doi => $p_spec->{joss_doi} }))
    ->on_create->set(set_arg('p',$p_spec)).';';

  # submission
  push @cypher, cypher->merge(ptn->N('s:submission', {joss_doi => $s_spec->{joss_doi}}))
    ->on_create->set(set_arg('s',$s_spec)).';';
  
  # person
  # editor
  push @cypher, cypher->merge(ptn->N('e:person', { handle => $ed_spec->{handle} })).';';
  # submitter
  my ($mrg_sa) = ($sa_spec->{handle} ? { handle => $sa_spec->{handle} } : { orcid => $sa_spec->{orcid} } );
  push @cypher, cypher->merge(ptn->N('b:person', $mrg_sa))
    ->on_create->set(set_arg('b',$sa_spec)).';';
  # reviewers
  for my $r_spec (@rev_specs) {
    push @cypher, cypher->merge(ptn->N('r:person', { handle => $r_spec->{handle} })).';';
  }
  # other authors
  for my $oth_spec (@other_au_specs) {
    my $mrg_o = ($oth_spec->{orcid} ? {orcid => $oth_spec->{orcid}} : {real_name => $oth_spec->{real_name}});
    push @cypher, cypher->merge(ptn->N('o:person', $mrg_o))
	->on_create->set(set_arg('o',$oth_spec)).';';
  }

  # paper -> submission
  push @cypher, cypher->match( ptn->C(ptn->N('p:paper', {joss_doi => $p_spec->{joss_doi}}),
				      ptn->N('s:submission', {joss_doi => $s_spec->{joss_doi}})) )
    ->merge( ptn->N('p')->R(':from_submission>')->N('s') ).';';
  
  # assignment
  # editor <- assign -> submission
  push @cypher, cypher->match(ptn->C(ptn->N('e:person',{handle => $ed_spec->{handle}}),
			      ptn->N('s:submission', {joss_doi => $s_spec->{joss_doi}})))
    ->create(ptn->N('e')->R('<:assigned_to')->N('a:assignment', {role => 'editor'})
	     ->R(':assigned_for>')->N('s')).';';

  # submitter <- assign(as submitter) -> submission
  push @cypher, cypher->match(ptn->C(ptn->N('b:person', $mrg_sa),
			      ptn->N('s:submission', {joss_doi => $s_spec->{joss_doi}})))
    ->create(ptn->N('b')->R('<:assigned_to')->N('a:assignment', {role => 'submitter'})
	     ->R(':assigned_for>')->N('s')).';';

  # submitter <- assign(as author) -> submission
  push @cypher, cypher->match(ptn->C(ptn->N('b:person', $mrg_sa),
			      ptn->N('s:submission', {joss_doi => $s_spec->{joss_doi}})))
    ->create(ptn->N('b')->R('<:assigned_to')->N('a:assignment', {role => 'author'})
	     ->R(':assigned_for>')->N('s')).';';

  # review <- assign -> submission
  for my $rev_spec (@rev_specs) {
    push @cypher, cypher->match(ptn->C(ptn->N('r:person',{handle => $rev_spec->{handle}}),
				ptn->N('s:submission', {joss_doi => $s_spec->{joss_doi}})))
      ->create(ptn->N('r')->R('<:assigned_to')->N('a:assignment', {role => 'reviewer'})
	       ->R(':assigned_for>')->N('s')).';';
  }

  # other_author <- assign -> submission
  for my $oth_spec (@other_au_specs) {
    my $mrg_o = ($oth_spec->{orcid} ? {orcid => $oth_spec->{orcid}} : {real_name => $oth_spec->{real_name}});
    push @cypher, cypher->match(ptn->C(ptn->N('o:person',$mrg_o),
				       ptn->N('s:submission', {joss_doi => $s_spec->{joss_doi}})))
      ->create(ptn->N('o')->R('<:assigned_to')->N('a:assignment', {role => 'author'})
	       ->R(':assigned_for>')->N('s')).';';
  }
}

for (@cypher) {
  s|\\_|_|g;
  say $_;
}

sub set_arg {
  my ($nd,$hash) = @_;
  my $ret = {};
  for (keys %$hash) {
    $ret->{"$nd\.$_"} = $hash->{$_} if defined $hash->{$_};
  }
  return $ret;
}
1;
