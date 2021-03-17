#!/usr/bin/env perl

use v5.16;

use URI;
use DBI;
use YAML::XS;
use Path::Tiny qw/ path /;

use Mustache::Simple;
use File::Fetch;
use IO::Uncompress::Unzip qw( unzip $UnzipError );

use Data::Dump qw/ dump /;

# ====================== #
# CONFIGURATION
# ====================== #

my $database = path( $0 )->parent->sibling( 'database' );
my $build = $database->child('build');

my $tache = new Mustache::Simple(throw => 0);


my $writer = DBI->connect ("dbi:CSV:", "", "", {
	    f_dir        =>  $database->stringify,
	    }) or die $DBI::errstr;
		

$build->mkpath();
		
foreach my $datasource ( $database->child('migrations')->children(qr/.yaml/) )
{
		# lets zero the playing feild
		$build->remove_tree( { keep_root => 1 } );
			
		my ( $config, $mappings, $create, $parse ) = Load( $datasource->slurp );
		
		say " [info] Now working on ".$config->{'title'};
				
		# download resource
		my $remote = File::Fetch->new( uri => $config->{ 'datasource' } )
					->fetch( to => $build );
		
		# unzip the file ( TODO: we could check to see if this is required )
		unzip $remote => $build->child( $config->{ 'filename' } )->stringify
							or die "unzip failed: $UnzipError\n";
		
		# --- MIGRATION ------ #
		
		my $reader = DBI->connect ("dbi:CSV:", "", "", {
		    f_dir        =>  $build->stringify,
		    }) or die $DBI::errstr;
		
		$database->child( $config->{'table'} )->remove;
			
		$writer->do( $tache->render( $create->{'sql'}, { table => $config->{'table'} } ) );
		
		my $sth = $reader->prepare ( 'SELECT * FROM '.$config->{'table'} );
		
		$sth->execute;
		
		my $cntr = 1;
		
		while (my $row = $sth->fetchrow_hashref() ) {
			
			my $dataset = { table => $config->{'table'}, _row_id => $cntr++  } ;
			
			foreach my $map (keys %$mappings )
			{
				if (ref( $mappings->{$map} ) eq 'ARRAY')
				{
					# this is a sum function
					my $sum = 0;
					
					$sum += $row->{ $_ } for @{ $mappings->{$map} };
					
					$dataset->{$map} = $sum;
					
					next;
				}
				
				$dataset->{$map} = $row->{ $mappings->{$map} };
			}
		    
			$writer->do( $tache->render ( $parse->{'sql'}, $dataset ) );
		}
		$sth->finish();
			
		
		# lets clear the datasource if exists
		# $datasource->child('db.csv')->remove
		#	if $datasource->child('db.csv')->is_file;
		
	
}

# lets zero the playing feild
$build->remove_tree( { keep_root => 1 } );


