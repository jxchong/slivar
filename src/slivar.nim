import ./slivarpkg/pedfile
import ./slivarpkg/duko
from ./slivarpkg/version import slivarVersion
import ./slivarpkg/evaluator
import ./slivarpkg/groups
import ./slivarpkg/comphet
import ./slivarpkg/duodel
import ./slivarpkg/gnotate
import ./slivarpkg/make_gnotate
import ./slivarpkg/tsv
import ./slivarpkg/counter
import strutils
import hts/vcf
import os
import tables
import times
import strformat
import argparse

proc kids(samples:seq[Sample]): seq[string] =
  for s in samples:
    if s.dad != nil and s.mom != nil: result.add(s.id)

proc expr_main*(dropfirst:bool=false) =

  var p = newParser("slivar expr"):
    option("-v", "--vcf", help="path to VCF/BCF")
    option("--region", help="optional region to limit evaluation. e.g. chr1 or 1:222-333 (or a BED file of regions)")
    option("-j", "--js", help="path to javascript functions to expose to user")
    option("-p", "--ped", help="pedigree file with family relations, sex, and affected status")
    option("-a", "--alias", help="path to file of group aliases")
    option("-o", "--out-vcf", help="path to output VCF/BCF", default="/dev/stdout")
    flag("--pass-only", help="only output variants that pass at least one of the filters")
    flag("--skip-non-variable", help="don't evaluate expression unless at least 1 sample is variable at the variant this can improve speed")
    option("--trio", help="expression(s) applied to each trio where 'mom', 'dad', 'kid' labels are available; trios inferred from ped file.", multiple=true)
    option("--family-expr", help="expression(s) applied to each family where 'fam' is available with a list of samples in each family from ped file.", multiple=true)
    option("--group-expr", help="expression(s) applied to the groups defined in the alias option [see: https://github.com/brentp/slivar/wiki/groups-in-slivar].", multiple=true)
    option("--sample-expr", help="expression(s) applied to each sample in the VCF.", multiple=true)
    option("--info", help="expression using only attributes from  the INFO field or variant. If this does not pass trio/group/sample expressions are not applied.")
    option("-g", "--gnotate", help="path(s) to compressed gnotate file(s)", multiple=true)

  var argv = commandLineParams()
  if dropfirst and len(argv) > 0:
      argv = argv[1..argv.high]
  if len(argv) > 0 and argv[0] == "expr":
    argv = argv[1..argv.high]
  if len(argv) == 0:
    argv = @["--help"]

  var opts = p.parse(argv)
  if opts.help:
    quit 0

  if opts.vcf == "":
    stderr.write_line "must specify the --vcf"
    quit p.help
  if opts.ped == "" and opts.alias == "" and opts.info == "" and len(opts.gnotate) == 0:
      stderr.write_line "must specify either --ped or --alias"
      quit p.help
  if opts.out_vcf == "":
    stderr.write_line "must specify the --out-vcf"
    quit p.help
  var
    ivcf:VCF
    ovcf:VCF
    groups: seq[Group]
    gnos:seq[Gnotater]
    samples:seq[Sample]

  if not open(ivcf, opts.vcf, threads=1):
    quit "couldn't open:" & opts.vcf

  let verbose=getEnv("SLIVAR_QUIET") == ""


  if opts.ped != "":
    samples = parse_ped(opts.ped, verbose=verbose)
    samples = samples.match(ivcf, verbose=verbose)
  else:
    for i, s in ivcf.samples:
      samples.add(Sample(id: s, i:i))
  if getEnv("SLIVAR_QUIET") == "":
    stderr.write_line &"[slivar] {samples.len} samples matched in VCF and PED to be evaluated"

  if not open(ovcf, opts.out_vcf, mode="w"):
    quit "couldn't open:" & opts.out_vcf

  if opts.alias != "":
    groups = parse_groups(opts.alias, samples)

  if opts.gnotate.len != 0:
    for p in opts.gnotate:
      var gno:Gnotater
      if not gno.open(p):
        quit "[slivar] failed to open gnotate file. please check path"
      gno.update_header(ivcf)
      gnos.add(gno)

  ovcf.copy_header(ivcf.header)
  var
    iTbl: seq[NamedExpression]
    trioExprs: seq[NamedExpression]
    groupExprs: seq[NamedExpression]
    sampleExprs: seq[NamedExpression]
    familyExprs: seq[NamedExpression]
    out_samples: seq[string] # only output kids if only trio expressions were specified

  if opts.trio.len != 0:
    trioExprs = ovcf.getNamedExpressions(opts.trio, opts.vcf)
  if opts.group_expr.len != 0:
    groupExprs = ovcf.getNamedExpressions(opts.group_expr, opts.vcf, trioExprs)
  if opts.sample_expr.len != 0:
    sampleExprs = ovcf.getNamedExpressions(opts.sample_expr, opts.vcf, trioExprs, groupExprs)

  if opts.family_expr.len != 0:
    if opts.ped == "":
      quit "error must specify --ped to use with --family-expr"
    familyExprs = ovcf.getNamedExpressions(opts.family_expr, opts.vcf, trioExprs, groupExprs, sampleExprs)

  doAssert ovcf.write_header
  var ev = newEvaluator(samples, groups, iTbl, trioExprs, groupExprs, familyExprs, sampleExprs, opts.info, gnos, field_names=id2names(ivcf.header), opts.skip_non_variable)
  if trioExprs.len != 0 and groupExprs.len == 0 and sampleExprs.len == 0:
    out_samples = samples.kids

  var counter = ev.initCounter()

  # set pass only if they have only info expr, otherwise, there's no point.
  if not opts.pass_only and ev.info_expression.ctx != nil and not ev.has_sample_expressions:
    opts.pass_only = true

  if opts.js != "":
    var js = $readFile(opts.js)
    ev.load_js(js)
  var t = cpuTime()
  var n = 10000

  var
    i = 0
    nerrors = 0
    written = 0
  for variant in ivcf.variants(opts.region):
    variant.vcf = ovcf
    i += 1
    if i mod n == 0:
      var secs = cpuTime() - t
      var persec = n.float64 / secs.float64
      stderr.write_line &"[slivar] {i} {variant.CHROM}:{variant.start} evaluated {n} variants in {secs:.1f} seconds ({persec:.1f}/second)"
      t = cpuTime()
      if i >= 20000:
        n = 100000
      if i >= 500000:
        n = 500000
    var any_pass = false
    for ns in ev.evaluate(variant, nerrors):
      if opts.pass_only and ns.sampleList.len == 0 and ns.name != "": continue
      any_pass = true
      if ns.name != "": # if name is "", then they didn't have any sample expressions.
        var ssamples = join(ns.sampleList, ",")
        if variant.info.set(ns.name, ssamples) != Status.OK:
          quit "error setting field:" & ns.name

        if ns.val != float32.low:
          counter.inc(ns.sampleList, ns.name)

    if nerrors / i > 0.2 and i >= 1000:
      quit &"too many errors {nerrors} out of {i}. please check your expression"

    if any_pass or (not opts.pass_only):
      doAssert ovcf.write_variant(variant)
      written.inc
  if getEnv("SLIVAR_QUIET") == "":
    stderr.write_line &"[slivar] Finished. evaluated {i} total variants and wrote {written} variants that passed your slivar expressions."

  ovcf.close()
  ivcf.close()
  if ev.has_sample_expressions:
    var summaryPath = getEnv("SLIVAR_SUMMARY_FILE")
    if summaryPath == "":
      stderr.write_line counter.tostring(out_samples)
    else:
      var fh: File
      if not open(fh, summaryPath, fmWrite):
        quit "[slivar] couldn't open summary file:" & summaryPath
      fh.write(counter.tostring(out_samples))
      fh.close()
      if getEnv("SLIVAR_QUIET") == "":
        stderr.write_line "[slivar] wrote summary table to:" & summaryPath


proc main*() =
  type pair = object
    f: proc(dropfirst:bool)
    description: string

  var dispatcher = {
    "expr": pair(f:expr_main, description:"filter and/or annotate with INFO, trio, sample, group expressions"),
    "make-gnotate": pair(f:make_gnotate.main, description:"make a gnotate zip file for a given VCF"),
    "compound-hets": pair(f:comphet.main, description:"find compound hets in a (previously filtered and gene-annotated) VCF"),
    "tsv": pair(f:tsv.main, description:"converted a filtered VCF to a tab-separated-value spreadsheet for final examination"),
    "duo-del": pair(f:duodel.main, description: "find large denovo deletions in parent-child duos using non-transmission from SNP VCF"),
    }.toOrderedTable

  if getEnv("SLIVAR_QUIET") == "":
    stderr.write_line "slivar version: " & slivarVersion
  var args = commandLineParams()
  if len(args) > 0 and args[0] == "gnotate":
    quit "[slivar] the `gnotate` sub-command has been removed. Use `slivar expr` (with --info) to get the same functionality."

  if len(args) == 0 or not (args[0] in dispatcher):
    stderr.write_line "\nCommands: "
    for k, v in dispatcher:
      echo &"  {k:<13}:   {v.description}"
    if len(args) > 0 and (args[0] notin dispatcher) and args[0] notin @["-h", "-help"]:
      echo &"unknown program '{args[0]}'"
    quit ""

  dispatcher[args[0]].f(false)

when isMainModule:
  main()

