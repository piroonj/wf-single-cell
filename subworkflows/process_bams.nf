import java.util.ArrayList;


process split_gtf_by_chroms {
    label "singlecell"
    cpus 1
    memory "1 GB"
    input:
        path("ref.gtf")
    output:
        path("*"), emit: chrom_gtf
    """
    gawk '/^[^#]/ {print>\$1".gtf"}' ref.gtf 
    """
}   


process get_contigs {
    label "singlecell"
    cpus 1
    memory "2 GB"
    input:
        tuple val(meta),
              path('sample.bam'),
              path('sample.bam.bai')

    output:
        tuple path("contigs"),
            val(meta),
            emit: contigs
    """
    samtools idxstats sample.bam \
        | gawk '/^[^*]/{print\$1}' \
        | gawk NF > contigs
    """
}


process generate_whitelist{
    label "singlecell"
    cpus 4
    memory "4 GB"
    input:
        tuple val(meta),
              path("barcodes/?_barcode.tsv")
    output:
        tuple val(meta),
              path("whitelist.tsv"),
              emit: whitelist
        tuple val(meta),
              path("kneeplot.png"),
              emit: kneeplot
        // Note: This is called "uncorrected", but they're actually counts of
        //       high quality exact matches to longlist. Low frequency barcodes
        //       are assumed to be false positives. The list is further
        //       filtered by the selected method (basically by abundance).
        tuple val(meta),
              path("high_qual_bc_counts.tsv"),
              emit: uncorrected_bc_counts
    // TODO: change this to take precomputed, filtered counts from extract_barcodes
    """
    workflow-glue create_shortlist \
        barcodes whitelist.tsv \
        --counts \
        --method quantile \
        --exp_cells ${meta['expected_cells']} \
        --plot "kneeplot.png" \
        --counts_out "high_qual_bc_counts.tsv" \
        --threads ${task.cpus}
    """
}


process assign_barcodes{
    label "singlecell"
    cpus 1
    memory "2 GB"
    input:
         tuple val(meta),
               path("whitelist.tsv"),
               path("extract_barcodes.tsv")
    output:
        tuple val(meta),
              path("bc_assign_counts.tsv"),
              emit: chrom_assigned_barcode_counts
        tuple val(meta),
              path("extract_barcodes_with_bc.tsv"),
              emit: tags
    """
    workflow-glue assign_barcodes \
        whitelist.tsv extract_barcodes.tsv \
        extract_barcodes_with_bc.tsv bc_assign_counts.tsv \
        --max_ed ${params.barcode_max_ed} \
        --min_ed_diff ${params.barcode_min_ed_diff}
    """
}


process combine_bams_and_tags {
    // Merge all BAM and tags files chunks
    label "wf_common"
    cpus params.threads
    memory "8 GB"
    input:
        tuple val(meta),
              path('bams/*aln.bam'),
              path('bams/*aln.bam.bai'),
              path('tags/*tags.tsv')
    output:
        tuple val(meta),
              path("*tagged.sorted.bam"), 
              path("*tagged.sorted.bam.bai"),
              emit: merged_bam
        tuple val(meta),
              path("chr_tags/*"),
              emit: merged_tags
    """
    samtools cat -b <(find bams -name '*aln.bam') \
    | samtools sort - -@ ${task.cpus} --write-index \
        -o "tagged.sorted.bam##idx##tagged.sorted.bam.bai"

    mkdir chr_tags
    # Find the chr column number
    files=(tags/*)
    chr_col=\$(awk -v RS='\t' '/chr/{print NR; exit}' "\${files[0]}")

    # merge the tags TSVs, keep header from first file and split entries by chromosome
    awk -F'\t' -v chr_col=\$chr_col 'FNR==1{hdr=\$0; next} \
    {if (!seen[\$chr_col]++) \
        print hdr>"chr_tags/"\$chr_col".tsv"; \
        print>"chr_tags/"\$chr_col".tsv"}' tags/*
    """
}


process stringtie {
    label "singlecell"
    cpus params.threads
    // Memory usage for this process is usually less than 3GB, but some cases it may go over this.
    memory = { 3.GB * task.attempt }
    maxRetries = 3
    errorStrategy = { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
    input:
        path 'ref_genome.fa'
        path 'ref_genome.fa.fai'
        tuple val(meta),
              path("align.bam"),
              path("align.bam.bai"),
              val(chr),
              path("chr.gtf")

    output:
        tuple val(meta),
              val(chr),
              path("transcriptome.fa"),
              path("chr.gtf"),
              path("stringtie.gff"),
              path("reads.fastq.gz"),
              emit: read_tr_map
    script:
    """
    # Add chromosome label (-l) to generated transcripts
    # so we don't get name collisions during file merge later
    samtools view -h align.bam ${chr}  \
        | tee >(
            stringtie -L ${params.stringtie_opts} -p ${task.cpus} \
                -G chr.gtf -l "${chr}.stringtie" -o "stringtie.gff" - ) \
        | samtools fastq \
        | bgzip --threads 2 -c > reads.fastq.gz
    # Get transcriptome sequence
    gffread -g ref_genome.fa -w "transcriptome.fa" "stringtie.gff"
    """
}


process align_to_transcriptome {
    label "singlecell"
    cpus params.threads
    memory = "32 GB"
    input:
        tuple val(meta),
              val(chr),
              path('transcriptome.fa'),
              path('chr.gtf'),
              path('stringtie.gff'),
              path("reads.fq.gz")
    output:
        tuple val(meta),
              val(chr),
              path("chr.gtf"),
              path("tr_align.bam"),
              path('stringtie.gff'),
              emit: read_tr_map
    script:
    def view_threads = 1
    def sort_threads = 3
    def mm2_threads = Math.max(task.cpus - view_threads - sort_threads, 4)
    """
    minimap2 -ax map-ont \
        --cap-kalloc 100m --cap-sw-mem 50m \
        --end-bonus 10 -p 0.9 -N 3 -t $mm2_threads \
        transcriptome.fa reads.fq.gz \
    | samtools view -h -@ $view_threads -b -F 2052 - \
    | samtools sort -n -@ $sort_threads --no-PG - > tr_align.bam
    """
}


process assign_features {
    label "singlecell"
    cpus 1
    // This step is performed per-chromosome. The tags file per chrom can vary
    // quite widely in size. We don't have a fixed memory size here in order
    // to get better parallelism on single-host setups.
    memory { 1.0.GB.toBytes() + (tags.size() * 2 ) }
    input:
        tuple val(meta),
              val(chr),
              path("chr.gtf"),
              path("tr_align.bam"),
              path('stringtie.gff'),
              path(tags, stageAs: 'tags.tsv')
    output:
        tuple val(meta),
              val(chr),
              path("feature_assigns.tsv"),
              emit: feature_assigns
        tuple val(meta),
              path("gffcompare.annotated.gtf"),
              emit: annotation
    """
    # gffcomapre maps transcript reference IDs to query transcripts.
    gffcompare -o gffcompare -r chr.gtf stringtie.gff

    workflow-glue assign_features \
        --transcriptome_bam tr_align.bam \
        --gffcompare_tmap gffcompare.stringtie.gff.tmap \
        --gtf chr.gtf \
        --tags tags.tsv \
        --output "feature_assigns.tsv" \
        --min_mapq ${params.gene_assigns_minqv}
    """
}


// Create expression matrices by combining barcode and feature
// tag files. Also outputs the combined tags (per-chrom) to be combined later
process create_matrix {
    label "singlecell"
    cpus 1
    // Benchmarking showed that memory usage was ~ 15x the size of read_tags input.
    // Set a minimum memory requirement of 1.0GB to allow for overhead.
    memory {1.0.GB.toBytes()  + (read_tags.size() * 20) }
    input:
        tuple val(meta), val(chr), path("features.tsv"), path(read_tags, stageAs: "barcodes.tsv")
    output:
        tuple val(meta), val(chr), path("summary.tsv"), emit: summary
        tuple val(meta), val(chr), val("gene"), path("expression.gene.hdf"), emit: gene
        tuple val(meta), val(chr), val("transcript"), path("expression.transcript.hdf"), emit: transcript
    """
    workflow-glue create_matrix \
        ${chr} barcodes.tsv features.tsv \
        --tsv_out summary.tsv \
        --hdf_out expression.hdf \
    """
}


// Combines multiple expression matrices (e.g. from different chromosomes)
// and calculates summary information on the matrix including UMAPs
process process_matrix {
    label "singlecell"
    cpus  1
    memory "16 GB"
    input:
        tuple val(meta), val(feature), path("inputs/*.hdf")
    output:
        tuple val(meta), val(feature), path("${feature}_raw_feature_bc_matrix"), emit: raw
        tuple val(meta), val(feature), path("${feature}_processed_feature_bc_matrix"), emit: processed
        tuple val(meta), val(feature), path("${feature}.expression.mean-per-cell.tsv"), emit: meancell
        tuple val(meta), val(feature), path("${feature}.expression.mito-per-cell.tsv"), emit: mitocell
        tuple val(meta), val(feature), path("${feature}.expression.umap*.tsv"), emit: umap
    publishDir:
        
    script:
    def mito_prefixes = params.mito_prefix.replaceAll(',', ' ')
    """
    export NUMBA_NUM_THREADS=${task.cpus}
    workflow-glue process_matrix \
        inputs/*.hdf \
        --feature ${feature} \
        --raw ${feature}_raw_feature_bc_matrix \
        --processed ${feature}_processed_feature_bc_matrix \
        --per_cell_mito ${feature}.expression.mito-per-cell.tsv \
        --per_cell_expr ${feature}.expression.mean-per-cell.tsv \
        --umap_tsv ${feature}.expression.umap.tsv \
        --enable_filtering \
        --min_features $params.matrix_min_genes \
        --min_cells $params.matrix_min_cells \
        --max_mito $params.matrix_max_mito \
        --mito_prefixes $mito_prefixes \
        --norm_count $params.matrix_norm_count \
        --enable_umap \
        --replicates 3 
    """
}


process combine_final_tag_files {
    // Combine the final
    label "singlecell"
    cpus 1
    memory "1 GB"
    input:
        tuple val(meta),
              path("tags*.tsv")
    output:
        tuple val(meta),
              path("read_tags.tsv")
    """
    awk 'FNR>1 || NR==1' *.tsv > "read_tags.tsv"
    """
}


process umi_gene_saturation {
    label "singlecell"
    cpus 4
    memory "32 GB"
    input:
        tuple val(meta),
              path("read_tags.tsv")
    output:
        tuple val(meta),
              path("*saturation_curves.png"),
              emit: saturation_curve
    """
    export POLARS_MAX_THREADS=$task.cpus

    workflow-glue calc_saturation \
        --output "saturation_curves.png" \
        --read_tags read_tags.tsv
    """
}


process tag_bam {
    label "singlecell"
    cpus 4
    memory "16 GB"
    input:
        tuple val(meta),
              path("align.bam"),
              path("align.bam.bai"),
              val(chr),
              path('tags.tsv')
    output:
         tuple val(meta),
              path("${chr}.tagged.bam"),
              path("${chr}.tagged.bam.bai"),
              emit: tagged_bam
    script:
    """
    workflow-glue tag_bam \
        align.bam "${chr}.tagged.bam" tags.tsv "${chr}" \
        --threads ${task.cpus}

    samtools index -@ ${task.cpus} "${chr}.tagged.bam"
    """
}


process combine_chrom_bams {
    // Merge all chromosome bams by sample_id
    label "wf_common"
    cpus params.threads
    memory "8 GB"
    input:
        tuple val(meta),
              path(chrom_bams),
              path('chrom.bam.bai')
    output:
        tuple val(meta),
              path("tagged.sorted.bam"),
              path("tagged.sorted.bam.bai"),
              emit: bam_fully_tagged
    """
    samtools merge -@ ${task.cpus - 1} --write-index \
        -o "tagged.sorted.bam##idx##tagged.sorted.bam.bai" ${chrom_bams};
    """
}


process pack_images {
    label "singlecell"
    cpus 1
    memory "1 GB"
    input:
        tuple val(meta),
              path("images_${meta.alias}/*")
    output:
         tuple val(meta),
              path("images_${meta.alias}")
    """
    echo packing images
    """
}


process merge_transcriptome {
    // Merge the annotated GFFs and transcriptome sequence files
    label "singlecell"
    cpus 1
    memory "2GB"
    input:
        tuple val(meta),
            path('fasta/?.fa'),
            path('gffs/?.gff')
    output:
        tuple val(meta),
            path("transcriptome.gff.gz"),
            path("transcriptome.fa.gz"),
            emit: merged_annotation
    """
    # Concatenate transcriptome files, remove comments (from gff) and compress
    find fasta/ -name '*.fa' -exec cat {} + | gzip > "transcriptome.fa.gz"
    find gffs/ -name '*.gff' -exec cat {} + |grep -v '^#' | gzip > "transcriptome.gff.gz"
    """
}


workflow process_bams {
    take:
        bam
        extracted_barcodes
        high_qual_bc_counts
        gtf
        ref_genome_fasta
        ref_genome_idx
    main:
        chr_gtf = split_gtf_by_chroms(gtf)
            .flatten()
            .map {file -> 
                // create [chr, gtf]
                tuple(file.baseName, file)}

        get_contigs(bam)

        contigs = get_contigs.out.contigs
            .splitCsv().map{it -> [it[0][0], it[1]]}

        // Keep only the contigs that are referenced in the gtf
        contigs = chr_gtf
            .cross(contigs) // -> [[ chr, chr.gtf], [chr, meta]]
            // [meta, chr, chr.gtf]
            .map {chr_gtf, chr_meta -> [chr_meta[1], chr_meta[0], chr_gtf[1]]}

        generate_whitelist(high_qual_bc_counts)

        assign_barcodes(
            generate_whitelist.out.whitelist
            .cross(extracted_barcodes)
            .map {it ->
                meta = it[0][0]
                whitelist = it[0][1]
                barcodes = it[1][1]
                [meta, whitelist, barcodes]})

        // Combine the BAM chunks and tags chunks
        // TODO: this process 
        //       i) combines BAMs into a single BAM
        //       ii) combines TAGs from chunks above and re-splits into separate per-chrom files
        //       It should be split into distinct cat_bams and cat_tags processes
        // The BAM output here is for the whole genome?
        combine_bams_and_tags(
            bam.groupTuple()
                .join(assign_barcodes.out.tags.groupTuple()))

        // Spread the chr tag files across
        chr_tags = combine_bams_and_tags.out.merged_tags
            .transpose()
            .map {meta, file -> [meta, file.baseName, file]}

        // Run stringtie per-chrom.
        // Note: this passes in the whole genome BAM but the
        //       .combine() runs this per-chrom such that we get
        //       out reads as fastq per-chrom
        stringtie(
            ref_genome_fasta,
            ref_genome_idx,
            combine_bams_and_tags.out.merged_bam
                .combine(chr_gtf))

        align_to_transcriptome(stringtie.out.read_tr_map)

        assign_features(
            align_to_transcriptome.out.read_tr_map
                .join(chr_tags, by: [0, 1]))

        create_matrix(
            assign_features.out.feature_assigns
                // Join on [sample meta, chr]
                .join(chr_tags, by: [0, 1]))

        // aggregate per-chrom expression matrices to create MEX and UMAP TSVs
        process_matrix(
            create_matrix.out.gene.groupTuple(by: [0, 2])
            .mix(
                create_matrix.out.transcript.groupTuple(by: [0, 2]))
            .map {meta, chroms, feature, hdfs -> [meta, feature, hdfs]})

        // construct per-read summary tables for end user
        final_read_tags = combine_final_tag_files(
            create_matrix.out.summary
                .groupTuple()
                .map{meta, chrs, files -> [meta, files]})

        // UMI saturation curves
        // TODO: this save figures with matplotlib -- just output
        //       data and plot in report with bokeh
        umi_gene_saturation(final_read_tags)

        // tag BAMs and merge per-chrom BAMs into one big one?
        // TODO: these steps should be combined to avoid writing the BAMs twice.
        //       Theres no good reason to output per-chrom BAMs. Just take the
        //       per-chrom tags and per-chrom bams and iterate through to
        //       produce one BAM directly
        tag_bam(combine_bams_and_tags.out.merged_bam
             // cross by sample_id on the output of create_matrix to return
             // [sample_id, chr, kit_name, bam, bai, tags.tsv]
            .cross(create_matrix.out.summary)
            .map {it -> it.flatten()[0, 1, 2, 4, 5 ]})
        if (params.merge_bam) {
            combine_chrom_bams(tag_bam.out.tagged_bam
                .groupTuple())
            // [sample_id, bam]
            tagged_bams = combine_chrom_bams.out.bam_fully_tagged
        } else {
            tagged_bams = tag_bam.out.tagged_bam
                // [sample_id, bam, bai]
                .map {it -> it[0, 1, 2]}
                .groupTuple()
        }

        // TODO: see above:
        //       i) we shouldn't be making ugly static images
        //       ii) this process simply stages images under a common folder
        //           that could just be done in output directly
        pack_images(
            generate_whitelist.out.kneeplot
                .concat(umi_gene_saturation.out.saturation_curve)
                .groupTuple())

        merge_transcriptome(
            assign_features.out.annotation.groupTuple()
                .join(stringtie.out.read_tr_map.groupTuple())
                .map{
                    meta, ann_tr_gff, chr, tr_fa, ref_gtf, str_gff, fastq ->
                    [meta, tr_fa, ann_tr_gff]})

    emit:
        results = umi_gene_saturation.out.saturation_curve
            .join(final_read_tags)
            .join(
                process_matrix.out.mitocell
                .filter{it[1] == "gene"}
                .map{it->[it[0], it[2]]})
            .join(
                process_matrix.out.umap
                .map{it->[it[0], it[2]]}
                .groupTuple(size:2)
                .map{key, files -> [key, files.flatten()]})
            .join(generate_whitelist.out.whitelist)
            .join(generate_whitelist.out.uncorrected_bc_counts)
            .join(generate_whitelist.out.kneeplot)
            .join(tagged_bams)
            .join(pack_images.out)
            .join(merge_transcriptome.out)
            .map{it -> it.flatten()}

        // Emit sperately for use in the report
        // TODO: it shouldn't be the concern of this process what goes in the report
        //       instead just collate everything possible per sample
        final_read_tags = final_read_tags
        plots = pack_images.out.collect{it -> it[1]}.collect()
        white_list = generate_whitelist.out.whitelist
        gene_mean_expression = process_matrix.out.meancell
            .filter{it[1] == "gene"}
            .map{it->[it[0], it[2]]}
        transcript_mean_expression = process_matrix.out.meancell
            .filter{it[1] == "transcript"}
            .map{it->[it[0], it[2]]}
        mitochondrial_expression = process_matrix.out.mitocell
            .filter{it[1] == "gene"}
            .map{it->[it[0], it[2]]}
        umap_matrices = process_matrix.out.umap
            .map{it->[it[0], it[2]]}
            .groupTuple(size:2)
            .map{key, files -> [key, files.flatten()]}
}
