# frozen_string_literal: true

require 'rails/generators'
require 'ripper'

module Writ
  module Generators
    class RoleableGenerator < Rails::Generators::NamedBase
      desc "Injects Writ::Roleable into an existing model"

      class_option :scoping_model, type: :boolean, default: false,
                   desc: "Set up as a scoping model (e.g. Organisation) that owns roles"

      def self.exit_on_failure?
        true
      end

      def inject_roleable
        model_path = "app/models/#{file_path}.rb"

        unless File.exist?(File.join(destination_root, model_path))
          say_status :skip, "#{model_path} not found", :yellow
          return
        end

        path = File.join(destination_root, model_path)
        source = File.read(path)
        line = declaration_line(Ripper.sexp(source), [], class_name)
        unless line && source.lines[line - 1].match?(/\A\s*class\s+[\w:]+(?:\s*<[^;]+)?\s*\n\z/)
          raise Thor::Error,
                "Cannot find a supported class declaration for #{class_name} in #{model_path}; " \
                'the class declaration must be multiline so the Roleable integration can be injected after its header'
        end
        declaration = source.lines[line - 1]
        indent = declaration[/\A\s*/].delete("\n") + '  '
        declarations = roleable_declarations(source, line)
        return if declarations.empty?

        code = declarations.map { |text| indent + text }.join("\n\n") + "\n\n"
        anchor = /\A(?:[^\n]*\n){#{line}}/
        inject_into_file model_path, code, after: anchor
      end

      private

      def declaration_line(node, namespace, expected)
        return unless node.is_a?(Array)
        if [:module, :class].include?(node[0])
          name = constant_name(node[1])
          return unless name
          full = name.start_with?('::') ? name.delete_prefix('::') : (namespace + [name]).join('::')
          if node[0] == :class && full == expected
            token = constant_token(node[1])
            return token[2][0]
          end
          body = node[node[0] == :class ? 3 : 2]
          return declaration_line(body, full.split('::'), expected)
        end
        node.each do |child|
          found = declaration_line(child, namespace, expected) if child.is_a?(Array)
          return found if found
        end
        nil
      end

      def constant_name(node)
        case node&.first
        when :const_ref, :var_ref then node[1][1]
        when :top_const_ref then "::#{node[1][1]}"
        when :const_path_ref then "#{constant_name(node[1])}::#{node[2][1]}"
        end
      end

      def constant_token(node)
        node[0] == :const_path_ref ? node[2] : node[1]
      end

      def roleable_declarations(source, target_line)
        # Parse declarations so formatting changes do not cause duplicate host code on reruns.
        syntax = Ripper.sexp(source)
        target = class_node_at_line(syntax, [], class_name, target_line)
        target_body = target&.[](3)
        declarations = []
        declarations << 'include Writ::Roleable' unless roleable_include?(target_body)
        declarations << (options[:scoping_model] ? 'as_roleable(scoping_model: true)' : 'as_roleable') unless as_roleable_call?(target_body)
        declarations
      end

      def class_node_at_line(node, namespace, expected, target_line)
        return unless node.is_a?(Array)
        if [:module, :class].include?(node[0])
          name = constant_name(node[1])
          return unless name
          full = name.start_with?('::') ? name.delete_prefix('::') : (namespace + [name]).join('::')
          if node[0] == :class
            token = constant_token(node[1])
            return node if full == expected && token[2][0] == target_line
          end
          body = node[node[0] == :class ? 3 : 2]
          return class_node_at_line(body, full.split('::'), expected, target_line)
        end
        node.each do |child|
          found = class_node_at_line(child, namespace, expected, target_line) if child.is_a?(Array)
          return found if found
        end
        nil
      end

      def roleable_include?(node)
        ast_nodes(node).any? do |candidate|
          include_call?(candidate) &&
            ast_nodes(candidate[2]).any? do |argument|
              constant_name(argument)&.delete_prefix('::') == 'Writ::Roleable'
            end
        end
      end

      def include_call?(node)
        return false unless node.is_a?(Array)

        (node[0] == :command && node.dig(1, 1) == 'include') ||
          (node[0] == :method_add_arg && node.dig(1, 0) == :fcall && node.dig(1, 1, 1) == 'include')
      end

      def as_roleable_call?(node)
        ast_nodes(node).any? do |candidate|
          case candidate&.first
          when :vcall, :fcall
            candidate.dig(1, 1) == 'as_roleable'
          when :method_add_arg
            candidate.dig(1, 0) == :fcall && candidate.dig(1, 1, 1) == 'as_roleable'
          when :command
            candidate.dig(1, 1) == 'as_roleable'
          end
        end
      end

      def ast_nodes(node)
        return [] unless node.is_a?(Array)

        [node] + node.flat_map { |child| ast_nodes(child) }
      end
    end
  end
end
