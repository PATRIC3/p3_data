#!/usr/bin/env perl

use strict;
use FindBin qw($Bin);
use Getopt::Long::Descriptive;
use Data::Dumper;

my $solrServer = $ENV{PATRIC_SOLR};
my $solrFormat="&wt=csv&csv.separator=%09&csv.mv.separator=;";

my ($opt, $usage) = 
	describe_options(
		"%c %o",
		["division=s", "Division: bacteria | archaea | phage | viral | plant, multivalued, comma-seperated"],
		["source=s", "Source: genbank | refseq", {default => "genbank"}],
		["status=s", "Status: new | replaced | all", {default => "new"}],
		["format=s", "Format: gbf | gff | fna | faa | ftb | none, multivalued, comma-seperated", { default => "none"}],
		["dir_path=s" , "ftp_path: path to the ftp directory for the reference genomes", { default => "genomes" }],
		[],
		["help|h", "Print usage message and exit"] );

print($usage->text), exit 0 if $opt->help;
print($usage->text), exit 1 unless $opt->division;
print($usage->text), exit 1 unless $opt->status;


my @divisions = split /,/, $opt->division;
my $source= $opt->source;
my $status = $opt->status;
my @formats= split /,/, $opt->format;


my $reference_data_dir = $opt->dir_path;
my $reference_genome_dir = $reference_data_dir;
my $reference_genome_staging_dir = $reference_data_dir;


`mkdir $reference_data_dir` unless (-d $reference_data_dir);
`mkdir $reference_genome_dir` unless (-d $reference_genome_dir);
`mkdir $reference_genome_staging_dir` unless (-d $reference_genome_staging_dir);


foreach my $division (@divisions){

	open TAB , ">$reference_genome_staging_dir/genome_summary_$division.txt";

	my @assemblies = getAssemblySummary($source, $division);

	foreach my $entry (@assemblies){

		chomp $entry;

		if ($entry=~/^#/) { #header
			my $header = $entry;
			$header =~s/^#/status\tdivision\t/;
			print TAB "$header\n";
			next;
		}

		next if $division=~/viral/ && not $entry=~/phage/i;

		my @attribs = split /\t/, $entry;

		my $assembly = {};
		$assembly->{accession} = $attribs[0];
		$assembly->{bioproject_accession} = $attribs[1];
		$assembly->{biosample_accession} = $attribs[2];
		$assembly->{wgs_accession} = $attribs[3];
		$assembly->{wgs_accession} =~s/\.\d*$//;
		$assembly->{status} = $attribs[10];
		$assembly->{name} = $attribs[15];
		$assembly->{ftp_dir} = $attribs[19];
		$assembly->{file} = $assembly->{ftp_dir};
		$assembly->{file}=~s/.*\///; 
		
		($assembly->{id}, $assembly->{version}) = $assembly->{accession}=~/(.*)\.(\d+)$/;
		$assembly->{dir} = $assembly->{accession}."_".$assembly->{name};

		#next unless $assembly->{accession} eq "GCA_001585065.1";

		next if ($assembly->{status} eq "replaced"); 	

		print "Processing assembly: $assembly->{accession}\n";  
		
		getMD5Checksums($assembly);
		my $assembly_status = checkAssemblyStatus($assembly);

		print TAB "$assembly_status\t$assembly->{genome_id}\t$division\t$entry\n";

		if ($assembly_status eq $status || $status eq "all"){

			#my $dir = "$reference_genome_staging_dir/$assembly->{accession}";

			#`mkdir $reference_genome_staging_dir/$assembly->{accession}` unless (-d "$reference_genome_staging_dir/$assembly->{accession}");

			getGenBankFile($assembly) if grep $_ eq "gbf", @formats;
			getGffFile($assembly) if grep $_ eq "gff", @formats;
			getFnaFile($assembly) if grep $_ eq "fna", @formats;
			getFaaFile($assembly) if grep $_ eq "faa", @formats;
			getFeatureTableFile($assembly) if grep $_ eq "ftb", @formats;
		
		}else{

			# Current version already in KBase, check for annotation updates
			
		}

	}

}

close TAB;


sub getAssemblySummary {

	my ($source, $division) = @_;
	my $assembly_summary_url;
	my @assemblies = ();

	if ($division=~/phage/){
		$assembly_summary_url = "ftp://ftp.ncbi.nlm.nih.gov/genomes/$source/viral/assembly_summary.txt";
		@assemblies = `wget -q -O - $assembly_summary_url | grep -i "phage"`;
	}else{
		$assembly_summary_url = "ftp://ftp.ncbi.nlm.nih.gov/genomes/$source/$division/assembly_summary.txt";
		@assemblies = `wget -q -O - $assembly_summary_url`;
	}

	return @assemblies;

}


sub getMD5Checksums{

	my ($assembly) = @_;

	print "\tRetrieving md5checksums.txt file for $assembly->{accession}\n";

	my $url = "$assembly->{ftp_dir}/md5checksums.txt";
	
	my @rows = `wget -q $url -O -`;

	foreach my $row (@rows) {
		$assembly->{md5}->{gbff}=$1 if $row=~/(\S*)\s.*genomic.gbff.gz/;	
		$assembly->{md5}->{gff}=$1 if $row=~/(\S*)\s.*genomic.gff.gz/;	
		$assembly->{md5}->{fna}=$1 if $row=~/(\S*)\s.*genomic.fna.gz/;	
		$assembly->{md5}->{faa}=$1 if $row=~/(\S*)\s.*protein.faa.gz/;	
		$assembly->{md5}->{feature_table}=$1 if$row=~/(\S*)\s.*feature_table.txt.gz/;	
	}

}


sub checkAssemblyStatus {

	my ($assembly) = @_;
	
	print "\tChecking status for assembly $assembly->{accession}: ";

	my $status;

	my $assembly_id_refseq = $assembly->{id};
	$assembly_id_refseq =~s/GCA/GCF/;
	my $assembly_accession_refseq = $assembly->{accession};
	$assembly_accession_refseq =~s/GCA/GCF/;
	
  my $core = "/genome";
  my $query = "/select?q=public:1 AND (assembly_accession:".$assembly->{id}."*". " OR assembly_accession:".$assembly_id_refseq."*"; 
	$query .= " OR biosample_accession:".$assembly->{biosample_accession} if $assembly->{biosample_accession};
	$query .= " OR genbank_accessions:".$assembly->{wgs_accession} if $assembly->{wgs_accession};
	$query .= ")";
  my $fields = "&fl=genome_id,genome_name,assembly_accession,biosample_accession,genbank_accessions";
  my $rows = "&rows=10";
  my $sort = "";
  my $solrQuery = $solrServer.$core.$query.$fields.$rows.$sort.$solrFormat;

	#print "\n$solrQuery\n";

  my @records = `wget -q -O - "$solrQuery" | grep -v genome_name`;

	#print (join "###", @records), "\n"; 

	if (scalar @records == 0 ){
		$status = "new";
	}elsif(scalar @records > 1 ){
		$status = "match: multiple";
	}else{
		my ($genome_id, $genome_name, $assembly_accession, $biosample_accession, $genbank_accession) = split /\t/, @records[0];

		if ($assembly_accession eq $assembly->{accession} || $assembly_accession eq $assembly_accession_refseq){
			$status = "match: current";
			$assembly->{genome_id} = $genome_id;
		}elsif ($assembly_accession =~/$assembly->{id}/ || $assembly_accession =~/$assembly_id_refseq/){
			$status = "match: replace";
			$assembly->{genome_id} = $genome_id;
		}else{
			$status = "match: unknown";
			$assembly->{genome_id} = $genome_id;
		}
	}  

	print "$status\n";

	return $status;

}


sub getGenBankFile {

	my ($assembly) = @_;

	print "\tRetrieving GenBank file for $assembly->{accession}: ";

	my $url = "$assembly->{ftp_dir}/$assembly->{file}\_genomic.gbff.gz";
	my $outfile = "$reference_genome_staging_dir/$assembly->{accession}.gbff.gz"; 
	
	my $err;	
	for (my $try=0; $try<5; $try++){
		$err = system("wget -q $url -O $outfile");
		last if $err == 0; 
	}

	my $md5 = computeMD5($outfile);
	if ($err == 0 && $md5 eq $assembly->{md5}->{gbff}){
			`gzip -df $outfile`;
			print "Success\n";
	}else{
			`rm $outfile`;
			print "Error => wget error code:$err\tMD5:$md5 vs $assembly->{md5}->{gbff}\n";
	}

}


sub getGffFile {

	my ($assembly) = @_;

	print "\tRetrieving GFF file for $assembly->{accession}: ";
	
	my $url = "$assembly->{ftp_dir}/$assembly->{file}\_genomic.gff.gz";
	my $outfile = "$reference_genome_staging_dir/$assembly->{accession}.gff.gz"; 
	
	my $err;	
	for (my $try=0; $try<5; $try++){
		$err = system("wget -q $url -O $outfile");
		last if $err == 0; 
	}

	my $md5 = computeMD5($outfile);
	if ($err == 0 && $md5 eq $assembly->{md5}->{gff}){
			`gzip -df $outfile`;
			print "Success\n";
	}else{
			`rm $outfile`;
			print "Error => wget error code:$err\tMD5:$md5 vs $assembly->{md5}->{gff}\n";
	}


}


sub getFnaFile {

	my ($assembly) = @_;

	print "\tRetrieving FNA file for $assembly->{accession}: ";

	my $url = "$assembly->{ftp_dir}/$assembly->{file}\_genomic.fna.gz";
	my $outfile = "$reference_genome_staging_dir/$assembly->{accession}.fna.gz"; 
	
	my $err;	
	for (my $try=0; $try<5; $try++){
		$err = system("wget -q $url -O $outfile");
		last if $err == 0; 
	}

	my $md5 = computeMD5($outfile);
	if ($err == 0 && $md5 eq $assembly->{md5}->{fna}){
			`gzip -df $outfile`;
			print "Success\n";
	}else{
			`rm $outfile`;
			print "Error => wget error code:$err\tMD5:$md5 vs $assembly->{md5}->{fna}\n";
	}

}


sub getFaaFile {

	my ($assembly) = @_;

	print "\tRetrieving FAA file for $assembly->{accession}: ";

	my $url = "$assembly->{ftp_dir}/$assembly->{file}\_protein.faa.gz";
	my $outfile = "$reference_genome_staging_dir/$assembly->{accession}.faa.gz"; 
	
	my $err;	
	for (my $try=0; $try<5; $try++){
		$err = system("wget -q $url -O $outfile");
		last if $err == 0; 
	}

	my $md5 = computeMD5($outfile);
	if ($err == 0 && $md5 eq $assembly->{md5}->{faa}){
			`gzip -df $outfile`;
			print "Success\n";
	}else{
			`rm $outfile`;
			print "Error => wget error code:$err\tMD5:$md5 vs $assembly->{md5}->{faa}\n";
	}

}


sub getFeatureTableFile {
	
	my ($assembly) = @_;

	print "\tRetrieving Feature Table file for $assembly->{accession}: ";

	my $url = "$assembly->{ftp_dir}/$assembly->{file}\_feature_table.txt.gz";
	my $outfile = "$reference_genome_staging_dir/$assembly->{accession}.feature_table.txt.gz"; 
	
	my $err;	
	for (my $try=0; $try<5; $try++){
		$err = system("wget -q $url -O $outfile");
		last if $err == 0; 
	}

	my $md5 = computeMD5($outfile);
	if ($err == 0 && $md5 eq $assembly->{md5}->{feature_table}){
			`gzip -df $outfile`;
			print "Success\n";
	}else{
			`rm $outfile`;
			print "Error => wget error code:$err\tMD5:$md5 vs $assembly->{md5}->{feature_table}\n";
	}

}


sub computeMD5 {

	my ($file) = @_;

	my $md5 = `md5sum $file | perl -pe 's/ .*\n//'`;
	
	return $md5;

}
