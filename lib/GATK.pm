package GATK;
use Moo;
use IO::File;
use IO::Dir;
extends 'Roll';

#-----------------------------------------------------------
##---------------------- ATTRIBUTES -------------------------
##-----------------------------------------------------------

has indels => (
		is      => 'rw',
		lazy    => 1,
		builder => '_build_indels',
	      );

has dbsnp => (
		is      => 'rw',
		lazy    => 1,
		builder => '_build_dbsnp',
	     );

has 'intervals' => (
		is      => 'rw',
		lazy    => 1,
		builder => '_build_intervals',

		);

##-----------------------------------------------------------
##------------------------ METHODS --------------------------
##-----------------------------------------------------------

sub _build_intervals {
	my $tape = shift;
	my $itv  = $tape->commandline->{interval_list};

	# create, print and store regions.
	my $REGION = IO::File->new( $itv, 'r' )
		or $tape->ERROR('Interval file could not be found or opened');

	my %regions;
	foreach my $reg (<$REGION>) {
		chomp $reg;
		my @chrs = split /:/, $reg;
		push @{ $regions{ $chrs[0] } }, $reg;
	}

	my @inv_file;
	foreach my $chr ( keys %regions ) {
		my $output_reg = $tape->output . "chr$chr" . "_region_file.list";

		if ( -e $output_reg ) {
			push @inv_file, $output_reg;
			next;
		}
		else {
			my $LISTFILE = IO::File->new( $output_reg, 'w' ) if $tape->execute;

			foreach my $list ( @{ $regions{$chr} } ) {
				print $LISTFILE "$list\n" if $tape->execute;
			}
			push @inv_file, $output_reg;
		}
	}
	my @sort_inv = sort @inv_file;
	return \@sort_inv;
}

##-----------------------------------------------------------

sub _build_indels {
	my $tape   = shift;
	my $knowns = $tape->options->{known_indels};

	$tape->ERROR('Issue building known indels from file') unless ($knowns);

	my $known_vcfs;
	foreach my $vcf ( @{$knowns} ) {
		chomp $vcf;
		next unless ( $vcf =~ /\.vcf$/ );
		$known_vcfs .= "--known $vcf ";
	}
	$tape->indels($known_vcfs);
}

##-----------------------------------------------------------

sub _build_dbsnp {
	my $tape   = shift;
	my $knowns = $tape->options->{known_dbsnp};

	$tape->ERROR('Issue building known dbsnp from file') unless ($knowns);

	my $known_vcfs = "--knownSites $knowns";
	$tape->dbsnp($known_vcfs);
}

##-----------------------------------------------------------

sub RealignerTargetCreator {
	my $tape = shift;
	$tape->pull;

	my $config  = $tape->options;
	my $opts = $tape->tool_options('RealignerTargetCreator');

	my $single = $tape->file_retrieve('bwa_mem');
	my $multi  = $tape->file_retrieve('sambamba_merge');

	my $combined;
	if   ($multi) { $combined = $multi }
	else          { $combined = $single }

	my @cmds;
	foreach my $in ( @{$combined} ) {
		my $parts = $tape->file_frags($in);

		foreach my $region ( @{ $tape->intervals } ) {

			my $reg_parts = $tape->file_frags($region);
			my $output =
				$tape->output
				. $parts->{parts}[0] . "_"
				. $reg_parts->{parts}[0]
				. '_realign.intervals';
			$tape->file_store($output);

			my $cmd = sprintf(
					"java -jar -Xmx%sg -XX:ParallelGCThreads=%s -Djava.io.tmpdir=%s "
					. "%s/GenomeAnalysisTK.jar -T RealignerTargetCreator "
					. "-R %s -I %s --num_threads %s %s -L %s -o %s\n",
					$opts->{xmx}, $opts->{gc_threads},
					$config->{tmp},      $config->{GATK},
					$config->{fasta},    $in,
					$opts->{num_threads}, $tape->indels,
					$region,           $output
					);
			push @cmds, $cmd;
		}
	}
	$tape->bundle( \@cmds );
}

##-----------------------------------------------------------

sub IndelRealigner {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('IndelRealigner');

	my $single = $tape->file_retrieve('bwa_mem');
	my $multi  = $tape->file_retrieve('sambamba_merge');

	my $combined;
	if   ($multi) { $combined = $multi }
	else          { $combined = $single }

	my $target = $tape->file_retrieve('RealignerTargetCreator');
	( my $known = $tape->indels ) =~ s/--known/-known/g;

	my @cmds;
	foreach my $dep ( @{$combined} ) {
		my $dep_parts = $tape->file_frags($dep);

		my @target_region = grep { /$dep_parts->{parts}[0]\_/ } @{$target};
		foreach my $region (@target_region) {

			my $reg_parts = $tape->file_frags($region);
			my $sub       = "_realign_" . $reg_parts->{parts}[1] . ".bam";

			# get call region from interval file
			my @intv =
				grep { /$reg_parts->{parts}[1]\_/ } @{ $tape->intervals };

			( my $output = $dep ) =~ s/\.bam/$sub/;
			$tape->file_store($output);

			my $cmd = sprintf(
					"java -jar -Xmx%sg -XX:ParallelGCThreads=%s -Djava.io.tmpdir=%s "
					. "%s/GenomeAnalysisTK.jar -T IndelRealigner -R %s -I %s -L %s -targetIntervals %s %s -o %s\n",
					$opts->{xmx}, $opts->{gc_threads},
					$config->{tmp},      $config->{GATK},
					$config->{fasta},    $dep,
					$intv[0],          $region,
					$known,            $output
					);
			push @cmds, $cmd;
		}
	}
	$tape->bundle( \@cmds );
}

##-----------------------------------------------------------

sub BaseRecalibrator {
	my $tape = shift;
	$tape->pull;

	my $config  = $tape->options;
	my $opts = $tape->tool_options('BaseRecalibrator');
	my $align = $tape->file_retrieve('IndelRealigner');

	my $known_indels = $tape->indels;
	$known_indels =~ s/known/knownSites/g;

	my @cmds;
	foreach my $aln ( @{$align} ) {
		my $file = $tape->file_frags($aln);

		( my $output = $file->{full} ) =~ s/\.bam/_recal_data.table/g;
		$tape->file_store($output);

		my $cmd = sprintf(
				"java -jar -Xmx%sg -XX:ParallelGCThreads=%s "
				. "-Djava.io.tmpdir=%s %s/GenomeAnalysisTK.jar -T BaseRecalibrator -R %s -I %s "
				."--num_cpu_threads_per_data_thread %s %s %s -o %s\n",
				$opts->{xmx}, $opts->{gc_threads},
				$config->{tmp},      $config->{GATK},
				$config->{fasta},    $aln,
				$opts->{num_cpu_threads_per_data_thread},
				$tape->dbsnp,
				$known_indels,     $output
				);
		push @cmds, $cmd;
	}
	$tape->bundle( \@cmds );
}

##-----------------------------------------------------------

sub PrintReads {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('PrintReads');
	my $table = $tape->file_retrieve('BaseRecalibrator');
	my $align = $tape->file_retrieve('IndelRealigner');

	my @cmds;
	foreach my $bam ( @{$align} ) {
		my $recal_t = shift @{$table};

		my $b_frag = $tape->file_frags($bam);
		my $r_frag = $tape->file_frags($recal_t);

		unless ( $b_frag->{parts}[0] eq $r_frag->{parts}[0] ) {
			$tape->ERROR('bam file and recal table not a match review commands');
		}

		( my $output = $bam ) =~ s/\.bam/_recal.bam/g;
		$tape->file_store($output);

		my $cmd = sprintf(
				"java -jar -Xmx%sg -XX:ParallelGCThreads=%s -Djava.io.tmpdir=%s "
				. "%s/GenomeAnalysisTK.jar -T PrintReads -R %s -I %s "
				."--num_cpu_threads_per_data_thread %s -BQSR %s -o %s\n",
				$opts->{xmx}, $opts->{gc_threads},
				$config->{tmp},      $config->{GATK},
				$config->{fasta},    $bam,
				$opts->{num_cpu_threads_per_data_thread},
				$recal_t,
				$output
				);
		push @cmds, $cmd;
	}
	$tape->bundle( \@cmds );
}

##-----------------------------------------------------------

sub HaplotypeCaller {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('HaplotypeCaller');

	# collect files and stack them.
	my $reads = $tape->file_retrieve('PrintReads');
	my @inputs = map { "$_" } @{$reads};

	my @cmds;
	foreach my $bam ( @{$reads} ) {
		my $file = $tape->file_frags($bam);

		if ( $tape->commandline->{file} ) {
			my $file = $tape->file_frags($bam);
			my $intv = $tape->intervals;

			foreach my $region ( @{$intv} ) {
				my $name = $file->{parts}[0];
				( my $output = $region ) =~
					s/_file.list/_$name.raw.snps.indels.gvcf/;

				$tape->file_store($output);

				my $cmd = sprintf(
						"java -jar -Xmx%sg -XX:ParallelGCThreads=%s -Djava.io.tmpdir=%s "
						. "%s/GenomeAnalysisTK.jar -T HaplotypeCaller -R %s "
						. "--num_cpu_threads_per_data_thread %s "
						. "--standard_min_confidence_threshold_for_calling %s "
						. "--standard_min_confidence_threshold_for_emitting %s "
						. "--emitRefConfidence %s "
						. "--variant_index_type %s "
						. "--variant_index_parameter %s "
						. "--min_base_quality_score %s "
						. "-I %s -L %s -o %s\n",
						$opts->{xmx}, $opts->{gc_thread},
						$config->{tmp},      $config->{GATK},
						$config->{fasta},    
						$opts->{num_cpu_threads_per_data_thread}, $opts->{standard_min_confidence_threshold_for_calling},
						$opts->{standard_min_confidence_threshold_for_emitting}, $opts->{emitRefConfidence},
						$opts->{variant_index_type}, $opts->{variant_index_parameter},
						$opts->{min_base_quality_score},
						$bam,              $region,
						$output
						);
				push @cmds, $cmd;
			}
		}
		else {
			my $file = $tape->file_frags($bam);

			my $search;
			foreach my $chr ( @{ $file->{parts} } ) {
				if ( $chr =~ /chr.*/ ) {
					$search = $chr;
				}
			}
			# get interval
			my @intv = grep { /$search\_/ } @{ $tape->intervals };

			my $name = $file->{parts}[0];
			( my $output = $intv[0] ) =~ s/_file.list/_$name.raw.snps.indels.gvcf/;

			$tape->file_store($output);

			my $cmd = sprintf(
					"java -jar -Xmx%sg -XX:ParallelGCThreads=%s -Djava.io.tmpdir=%s "
					. "%s/GenomeAnalysisTK.jar -T HaplotypeCaller -R %s "
					. "--num_cpu_threads_per_data_thread %s "
					. "--standard_min_confidence_threshold_for_calling %s "
					. "--standard_min_confidence_threshold_for_emitting %s "
					. "--emitRefConfidence %s "
					. "--variant_index_type %s "
					. "--variant_index_parameter %s "
					. "--min_base_quality_score %s "
					. "-I %s -L %s -o %s\n",
					$opts->{xmx}, $opts->{gc_threads},
					$config->{tmp},      $config->{GATK},
					$config->{fasta},    
					$opts->{num_cpu_threads_per_data_thread}, $opts->{standard_min_confidence_threshold_for_calling},
					$opts->{standard_min_confidence_threshold_for_emitting}, $opts->{emitRefConfidence},
					$opts->{variant_index_type}, $opts->{variant_index_parameter},
					$opts->{min_base_quality_score},
					$bam,              $intv[0],
					$output
					);
			push @cmds, $cmd;
		}
	}
	$tape->bundle( \@cmds );
}

##-----------------------------------------------------------

sub CatVariants {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;

	my $gvcf = $tape->file_retrieve('HaplotypeCaller');
	my @iso = grep { /\.gvcf$/ } @{$gvcf};

	my %indiv;
	my $path;
	foreach my $gvcf (@iso) {
		chomp $gvcf;

		my $frags = $tape->file_frags($gvcf);

		# make a soft link so catvariants works (needs vcf)
		( my $vcf = $gvcf ) =~ s/gvcf/vcf/;
		system("ln -s $gvcf $vcf") if ( $tape->execute );

		# then make a working version and collect path
		( my $file = $frags->{name} ) =~ s/gvcf/vcf/;
		$path = $frags->{path};

		my $key = $frags->{parts}[2];
		push @{ $indiv{$key} }, $file;
	}

	my @cmds;
	foreach my $samp ( keys %indiv ) {
		chomp $samp;

		# put the file in correct order.
		my @ordered_list;
		for ( 1 .. 22, 'X', 'Y', 'MT' ) {
			my $chr      = 'chr' . $_;
			my @value    = grep { /$chr\_/ } @{ $indiv{$samp} };
			my $fullPath = $path . $value[0];
			push @ordered_list, $fullPath;
		}

		my $variant = join( " -V ", @ordered_list );
		$variant =~ s/^/-V /;

		( my $output = $samp ) =~ s/vcf/Cat.vcf/;
		my $pathFile = $path . $output;
		$tape->file_store($pathFile);

		my $cmd = sprintf(
				"java -cp %s/GenomeAnalysisTK.jar org.broadinstitute.gatk.tools.CatVariants -R %s --assumeSorted  %s -out %s\n",
				$config->{GATK}, $config->{fasta}, 
				$variant,      $pathFile
				);
		push @cmds, $cmd;
	}
	$tape->bundle( \@cmds );
}

##-----------------------------------------------------------

sub CombineGVCF {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('CombineGVCF');

	my $gvcf = $tape->file_retrieve('CatVariants');
	my @iso = grep { /\.vcf$/ } @{$gvcf};

	my $chunk = $tape->commandline->{combine_chunk};

	my @cmds;
	if ( $tape->commandline->{combine_chunk} ) {
		my @var;
		push @var, [ splice @iso, 0, $chunk ] while @iso;

		my $id;
		foreach my $chunk (@var) {
			my $variants = join( " --variant ", @$chunk );

			$id++;
			my $output = $tape->output . $config->{ugp_id} . ".$id.mergeGvcf.vcf";
			$tape->file_store($output);

			my $cmd = sprintf(
					"java -jar -Xmx%sg -XX:ParallelGCThreads=%s %s/GenomeAnalysisTK.jar "
					. " -T CombineGVCFs -R %s "
					. "--variant %s -o %s\n",
					$opts->{xmx}, $opts->{gc_threads},
					$config->{GATK}, $config->{fasta}, $variants, $output
					);

			push @cmds, $cmd;
		}
	}
	else {
		my $variants = join( " --variant ", @iso );

		my $output = $tape->output . $config->{ugp_id} . '_final_mergeGvcf.vcf';
		$tape->file_store($output);

		my $cmd = sprintf(
				"java -jar -Xmx%sg -XX:ParallelGCThreads=%s %s/GenomeAnalysisTK.jar "
				. " -T CombineGVCFs -R %s --variant %s -o %s\n",
				$opts->{xmx}, $opts->{gc_threads},
				$config->{GATK}, $config->{fasta}, $variants, $output
				);

		push @cmds, $cmd;
	}
	$tape->bundle( \@cmds );
}

##-----------------------------------------------------------

sub GenotypeGVCF {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('GenotypeGVCF');

	my $single = $tape->file_retrieve('CombineGVCF');
	my @merged = grep { /mergeGvcf.vcf$/ } @{$single};

	# collect the 1k backgrounds.
	if ( $config->{backgrounds} ) {

		my $BK = IO::Dir->new( $config->{backgrounds} )
			or $tape->ERROR('Could not find/open background directory');

		# push 'em on!
		# http://open.spotify.com/track/2RnWnqnMqBuFosND1hbGjk
		foreach my $back ( $BK->read ) {
			next unless ( $back =~ /mergeGvcf.vcf$/ );
			chomp $back;
			my $fullpath = $config->{backgrounds} . "/$back";
			push @merged, $fullpath;
		}
		$BK->close;
	}
	my $variants = join( " --variant ", @merged );

	# here I just get the list files.
	my $lists = $tape->intervals;

	my @cmds;
	my $id;
	foreach my $region ( @{$lists} ) {
		$id++;
		my $output = $tape->output . $config->{ugp_id} . "\_$id\_genotyped.vcf";
		$tape->file_store($output);

		my $cmd = sprintf(
				"java -jar -Xmx%sg -XX:ParallelGCThreads=%s -Djava.io.tmpdir=%s "
				. "%s/GenomeAnalysisTK.jar -T GenotypeGVCFs -R %s "
				. "--num_threads %s --variant %s -L %s -o %s\n",
				$opts->{xmx}, $opts->{gc_threads},
				$config->{tmp},      $config->{GATK},
				$config->{fasta}, $opts->{num_threads},
				$variants,         $region,
				$output
				);
		push @cmds, $cmd;
	}
	$tape->bundle( \@cmds );
}

##-----------------------------------------------------------

sub Combine_Genotyped {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;

	my $genotpd = $tape->file_retrieve('GenotypeGVCF');

	my $output = $tape->output . $config->{ugp_id} . '_genotyped.vcf';
	$tape->file_store($output);

	my $cmd = sprintf(
			"java -cp %s/GenomeAnalysisTK.jar org.broadinstitute.gatk.tools.CatVariants "
			. "-R %s --assumeSorted -V %s -out %s\n",
			$config->{GATK}, $config->{fasta}, 
			join( " -V ", @{$genotpd} ), $output 
			);
	$tape->bundle( \$cmd );
}

##-----------------------------------------------------------

sub VariantRecalibrator_SNP {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('VariantRecalibrator_SNP');

	my $genotpd = $tape->file_retrieve('Combine_Genotyped');

	my $recalFile =
		'-recalFile ' . $tape->output . $config->{ugp_id} . '_snp_recal';
	my $tranchFile =
		'-tranchesFile ' . $tape->output . $config->{ugp_id} . '_snp_tranches';
	my $rscriptFile =
		'-rscriptFile ' . $tape->output . $config->{ugp_id} . '_snp_plots.R';

	$tape->file_store($recalFile);
	$tape->file_store($tranchFile);

	my $resource = $config->{resource_SNP};
	my $anno     = $config->{use_annotation_SNP};

	my $cmd = sprintf(
			"java -jar -Xmx%sg -XX:ParallelGCThreads=%s -Djava.io.tmpdir=%s %s/GenomeAnalysisTK.jar "
			. " -T VariantRecalibrator -R %s --minNumBadVariants %s --num_threads %s "
			. "-resource:%s -an %s -input %s %s %s %s -mode SNP\n",
			$opts->{xmx}, $opts->{gc_threads},
			$config->{tmp},      $config->{GATK},
			$config->{fasta},   
			$opts->{minNumBadVariants},
			$opts->{num_threads},
			join( ' -resource:', @$resource ), join( ' -an ', @$anno ),
			@$genotpd,   $recalFile,
			$tranchFile, $rscriptFile
			);
	$tape->bundle( \$cmd );
}

##-----------------------------------------------------------

sub VariantRecalibrator_INDEL {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('VariantRecalibrator_INDEL');

	my $genotpd = $tape->file_retrieve('Combine_Genotyped');

	my $recalFile =
		'-recalFile ' . $tape->output . $config->{ugp_id} . '_indel_recal';
	my $tranchFile =
		'-tranchesFile ' . $tape->output . $config->{ugp_id} . '_indel_tranches';
	my $rscriptFile =
		'-rscriptFile ' . $tape->output . $config->{ugp_id} . '_indel_plots.R';

	$tape->file_store($recalFile);
	$tape->file_store($tranchFile);

	my $resource = $config->{resource_INDEL};
	my $anno     = $config->{use_annotation_INDEL};

	my $cmd = sprintf(
			"java -jar -Xmx%sg -XX:ParallelGCThreads=%s -Djava.io.tmpdir=%s %s/GenomeAnalysisTK.jar -T VariantRecalibrator "
			. "-R %s --minNumBadVariants %s --num_threads %s -resource:%s -an %s -input %s %s %s %s -mode INDEL\n",
			$opts->{xmx}, $opts->{gc_threads},
			$config->{tmp},      $config->{GATK},
			$config->{fasta},    
			$opts->{minNumBadVariants},
			$opts->{num_threads},
			join( ' -resource:', @$resource ), join( ' -an ', @$anno ),
			@$genotpd,   $recalFile,
			$tranchFile, $rscriptFile
			);
	$tape->bundle( \$cmd );
}

##-----------------------------------------------------------

sub ApplyRecalibration_SNP {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('ApplyRecalibration_SNP');

	my $recal_files = $tape->file_retrieve('VariantRecalibrator_SNP');
	my $get         = $tape->file_retrieve('Combine_Genotyped');
	my $genotpd     = shift @{$get};

	# need to add a copy because it here.
	( my $output = $genotpd ) =~ s/_genotyped.vcf$/_recal_SNP.vcf/g;
	$tape->file_store($output);

	my $cmd = sprintf(
			"java -jar -Xmx%sg -Djava.io.tmpdir=%s %s/GenomeAnalysisTK.jar -T ApplyRecalibration "
			. "-R %s --ts_filter_level %s --num_threads %s --excludeFiltered -input %s %s %s -mode SNP -o %s\n",
			$opts->{xmx},     $config->{tmp},          $config->{GATK},
			$config->{fasta},        
			$opts->{ts_filter_level},
			$opts->{num_threads},
			$genotpd,
			shift @{$recal_files}, shift @{$recal_files}, $output
			);
	$tape->bundle( \$cmd );
}

##-----------------------------------------------------------

sub ApplyRecalibration_INDEL {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('ApplyRecalibration_INDEL');
	my $recal_files = $tape->file_retrieve('VariantRecalibrator_INDEL');
	my $get         = $tape->file_retrieve('Combine_Genotyped');
	my $genotpd     = shift @{$get};

	# need to add a copy because it here.
	( my $output = $genotpd ) =~ s/_genotyped.vcf$/_recal_INDEL.vcf/g;
	$tape->file_store($output);

	my $cmd = sprintf(
			"java -jar -Xmx%sg -Djava.io.tmpdir=%s %s/GenomeAnalysisTK.jar -T ApplyRecalibration "
			. "-R %s --ts_filter_level %s --num_threads %s --excludeFiltered -input %s %s %s -mode INDEL -o %s\n",
			$opts->{xmx},     $config->{tmp},          $config->{GATK},
			$config->{fasta},        
			$opts->{ts_filter_level},
			$opts->{num_threads},
			$genotpd,
			shift @{$recal_files}, shift @{$recal_files}, $output
			);
	$tape->bundle( \$cmd );
}

##-----------------------------------------------------------

sub CombineVariants {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('CombineVariants');

	my $snp_files   = $tape->file_retrieve('ApplyRecalibration_SNP');
	my $indel_files = $tape->file_retrieve('ApplyRecalibration_INDEL');

	my @app_snp = map { "--variant $_ " } @{$snp_files};
	my @app_ind = map { "--variant $_ " } @{$indel_files};

	my $output = $config->{output} . $config->{ugp_id} . "_Combined.vcf";
	$tape->file_store($output);

	my $cmd = sprintf(
			"java -jar -Xmx%sg -Djava.io.tmpdir=%s %s/GenomeAnalysisTK.jar -T CombineVariants -R %s "
			. "--num_threads %s --genotypemergeoption %s %s %s -o %s",
			$opts->{xmx}, $config->{tmp}, $config->{GATK}, $config->{fasta},
			$opts->{num_threads},
			$opts->{genotypemergeoption},
			join( " ", @app_snp ),
			join( " ", @app_ind ), $output
			);
	$tape->bundle( \$cmd );
}

##-----------------------------------------------------------

sub SelectVariants {
	my $tape = shift;
	$tape->pull;

	my $config = $tape->options;
	my $opts = $tape->tool_options('SelectVariants');

	my $comb_files = $tape->file_retrieve('CombineVariants');

	my $output = $config->{output} . $config->{ugp_id} . "_Final+Backgrounds.vcf";
	$tape->file_store($output);

	my $cmd = sprintf(
			"java -jar -Xmx%sg -Djava.io.tmpdir=%s %s/GenomeAnalysisTK.jar -T SelectVariants -R %s "
			. "--variant %s  -select \"DP > 100\" -o %s",
			$opts->{xmx}, $config->{tmp}, $config->{GATK}, $config->{fasta},
			shift @{$comb_files}, $output 
			);
	$tape->bundle( \$cmd );
}

##-----------------------------------------------------------

1;
