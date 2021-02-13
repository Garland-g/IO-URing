#!/usr/bin/env raku
use v6;

sub MAIN(:$test, :$install is copy) {
  configure();
  test() or $install = False if $test;
  install() if $install;
}

sub configure() {
  my %vars;
  %vars<CC> = $*VM.config<cc> // $*VM.config<nativecall.cc> // 'cc';
  %vars<uringhelper> = uringhelper().Str;
  %vars<EXECUTABLE> = $*EXECUTABLE;
  mkdir "resources" unless "resources".IO.e;
  mkdir "resources/libraries" unless "resources/libraries".IO.e;
  my $makefile = slurp('Makefile.in');
  for %vars.kv -> $k, $v {
    $makefile ~~ s:g/\%$k\%/$v/;
  }
  spurt('Makefile', $makefile);
}

sub test() {
  run($*VM.config<make>, 'test').exitcode == 0
}

sub install() {
  my $repo = %*ENV<DESTREPO>
    ?? Compunit::RepositoryRegistry.repository-for-name(%*ENV<DESTREPO>)
    !! (
        Compunit::RepositoryRegistry.repository-for-name('site'),
        |$*REPO.repo-chain.grep(Compunit::Repository::Installable)
      ).first(*.can-install)
      or die "Cannot find a repository to install to";

  say "Installing into $repo";
  my $dist = Distribution::Path.new($*CWD);

  my $uringhelper = uringhelper;
  $dist.meta<files> = (
    |$dist.meta<files>.grep(* ne $uringhelper.Str),
    {'resources/libraries/uringhelper' => $uringhelper},
  );

  $repo.install($dist);
  say "Installed successfully.";
}

sub uringhelper() {
  'resources'.IO.child('libraries').child($*VM.platform-library-name('uringhelper'.IO))
}
