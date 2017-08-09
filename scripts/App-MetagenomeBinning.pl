
#
# Metagenomic binning application.
#
#
# 1. Start with reads from a sample or set of samples. This is one or more fastq files.
# 
# 2. Combine to form a single paired-end file, a requirement of spades (?).
#
# 3. Assemble with Spades with the metagenome settings.
#
# 4. This gives you a set of contigs in a single fasta file. This is the alternate
#    starting point of the application.
#
# 5. Run bins_coverage. This gives you two output data files with coverage information.
#    output.contigs2reads.txt
#    (Look for sample data in Seedtk/DataGlobal. 
#    Reference map - seedprot.fa
#
# 6. Run bins.generate. This creates 
#         bins.json (describes the bins)
#	  ref.genomes.scores.tbl (best hits)
#
# 7. Run bins.fasta. Creates the bins fasta files.
#
# 8. Annotate bins with RAST.
#
# 9. Run checkm lineage workflow.
#
# 10. Run gordon role checker to get role completeness data.
#
# 11. Compute overall quality assessment.
#