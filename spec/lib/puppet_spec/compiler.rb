# frozen_string_literal: true

module PuppetSpec::Compiler
  module_function

  def compile_to_catalog(string, node = Puppet::Node.new('test'))
    Puppet[:code] = string
    # see lib/puppet/indirector/catalog/compiler.rb#filter
    Puppet::Parser::Compiler.compile(node).filter(&:virtual?)
  end

  # Does not removed virtual resources in compiled catalog (i.e. keeps unrealized)
  def compile_to_catalog_unfiltered(string, node = Puppet::Node.new('test'))
    Puppet[:code] = string
    # see lib/puppet/indirector/catalog/compiler.rb#filter
    Puppet::Parser::Compiler.compile(node)
  end

  def compile_to_ral(manifest, node = Puppet::Node.new('test'))
    catalog = compile_to_catalog(manifest, node)
    ral = catalog.to_ral
    ral.finalize
    ral
  end

  def compile_to_relationship_graph(manifest, prioritizer = Puppet::Graph::SequentialPrioritizer.new)
    ral = compile_to_ral(manifest)
    graph = Puppet::Graph::RelationshipGraph.new(prioritizer)
    graph.populate_from(ral)
    graph
  end

  def apply_compiled_manifest(manifest, prioritizer = Puppet::Graph::SequentialPrioritizer.new, &)
    args = transaction_report_args
    catalog = compile_to_ral(manifest)
    catalog.resources.each(&) if block_given?
    transaction = Puppet::Transaction.new(catalog, Puppet::Transaction::Report.new(*args), prioritizer)
    transaction.evaluate
    transaction.report.finalize_report

    transaction
  end

  def transaction_report_args
    return [] unless Puppet.version.to_f < 5.0

    # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Puppet::Transaction::Persistence).to receive(:save)
    # rubocop:enable RSpec/AnyInstance
    ['apply']
  end

  def apply_with_error_check(manifest)
    apply_compiled_manifest(manifest) do |res|
      expect(res).not_to receive(:err)
    end
  end

  def order_resources_traversed_in(relationships)
    order_seen = []
    relationships.traverse { |resource| order_seen << resource.ref }
    order_seen
  end

  def collect_notices(code, node = Puppet::Node.new('foonode'))
    Puppet[:code] = code
    compiler = Puppet::Parser::Compiler.new(node)
    node.environment.check_for_reparse
    logs = []
    Puppet::Util::Log.with_destination(Puppet::Test::LogCollector.new(logs)) do
      yield(compiler)
    end
    logs.select { |log| log.level == :notice }.map(&:message)
  end

  def eval_and_collect_notices(code, node = Puppet::Node.new('foonode'), topscope_vars = {}, &block)
    collect_notices(code, node) do |compiler|
      compile_with_notice_variables(compiler, topscope_vars, &block)
    end
  end

  def compile_with_notice_variables(compiler, variables, &block)
    set_topscope_variables(compiler, variables)
    return compiler.compile unless block

    compiler.compile do |catalog|
      yield(compiler.topscope, catalog)
      catalog
    end
  end

  def set_topscope_variables(compiler, variables)
    return if variables.empty?

    scope = compiler.topscope
    variables.each { |key, value| scope.setvar(key, value) }
  end

  # Compiles a catalog, and if source is given evaluates it and returns its result.
  # The catalog is returned if no source is given.
  # Topscope variables are set before compilation
  # Uses a created node 'testnode' if none is given.
  # (Parameters given by name)
  #
  def evaluate(code: 'undef', source: nil, node: Puppet::Node.new('testnode'), variables: {})
    source_location = caller(0..0)
    Puppet[:code] = code
    compiler = Puppet::Parser::Compiler.new(node)
    set_topscope_variables(compiler, variables)

    if source.nil?
      compiler.compile
      # see lib/puppet/indirector/catalog/compiler.rb#filter
      return compiler.filter(&:virtual?)
    end

    # evaluate given source is the context of the compiled state and return its result
    evaluate_source(compiler, source, source_location)
  end

  def evaluate_source(compiler, source, source_location)
    compiler.compile do |_catalog|
      Puppet::Pops::Parser::EvaluatingParser.singleton.evaluate_string(compiler.topscope, source, source_location)
    end
  end
end
