use Module::Build;
$build = Module::Build->new(
  perl => 5.0100001,
  dist_name => 'JOSS-graph',
  dist_abstract => 'Utilities for creating and maintaining a Neo4j graph database for JOSS',
  dist_version_from => 'lib/JOSS.pm',
  dist_author => 'Mark A. Jensen',
  license => 'perl',
  configure_requires => {
    'Module::Build' => 0,
  },
  requires => {
    'JSON::ize' => 0.202,
    'utf8::all' => 0,
    'Try::Tiny' => 0,
    'IPC::Run' => 0,
    'Log::Log4perl::Tiny' => 0,
    'XML::Twig' => 0,
    'Template::Tiny' => 0,
    'DBD::Neo4p' => 0.2001,
    'Neo4j::Cypher::Abstract' => 0.1003,
    'Set::Scalar' => 0,
    'Mojolicious' => 8.29,
    'Mojo::URL' => 0,
    'Mojo::UserAgent' => 0,
    'Net::GitHub::V4' => 0,
  },
 );
$build->create_build_script;
