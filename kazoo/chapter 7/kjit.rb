# Author:      Chris Wailes <chris.wailes@gmail.com>
# Project:     Compiler Examples
# Date:        2011/05/11
# Description: This file sets up a JITing execution engine for Kazoo.

# RLTK Files
require 'rcgtk/llvm'
require 'rcgtk/module'
require 'rcgtk/execution_engine'
require 'rcgtk/value'

# Inform LLVM that we will be targeting an x86 architecture.
RCGTK::LLVM.init(:X86)

module Kazoo7

	ZERO = RCGTK::Double.new(0.0)

	class JIT
		attr_reader :module

		def initialize
			# IR building objects.
			@module  = RCGTK::Module.new('Kazoo JIT')
			@builder = RCGTK::Builder.new
			@st      = Hash.new

			# Execution Engine
			@engine = RCGTK::JITCompiler.new(@module)

			# Add passes to the Function Pass Manager.
			@module.fpm.add(:InstCombine, :Reassociate, :GVN, :CFGSimplify)
		end

		def add(ast)
			case ast
			when Expression then translate_function(Function.new(Prototype.new('', []), ast))
			when Function   then translate_function(ast)
			when Prototype  then translate_prototype(ast)
			else raise 'Attempting to add an unhandled node type to the JIT.'
			end
		end

		def execute(fun, *args)
			@engine.run_function(fun, *args)
		end

		def optimize(fun)
			@module.fpm.run(fun)

			fun
		end

		def translate_expression(node)
			case node
			when Binary
				left  = translate_expression(node.left)
				right = translate_expression(node.right)

				case node
				when Add
					@builder.fadd(left, right, 'addtmp')

				when Sub
					@builder.fsub(left, right, 'subtmp')

				when Mul
					@builder.fmul(left, right, 'multmp')

				when Div
					@builder.fdiv(left, right, 'divtmp')

				when LT
					cond = @builder.fcmp(:ult, left, right, 'cmptmp')
					@builder.ui2fp(cond, RCGTK::DoubleType, 'booltmp')

				when GT
					cond = @builder.fcmp(:ugt, left, right, 'cmptmp')
					@builder.ui2fp(cond, RCGTK::DoubleType, 'booltmp')

				when Eql
					cond = @builder.fcmp(:ueq, left, right, 'cmptmp')
					@builder.ui2fp(cond, RCGTK::DoubleType, 'booltmp')

				when Or
					left  = @builder.fcmp(:une, left, ZERO, 'lefttmp')
					right = @builder.fcmp(:une, right, ZERO, 'righttmp')

					int = @builder.or(left, right, 'ortmp')

					@builder.ui2fp(int, RCGTK::DoubleType, 'booltmp')

				when And
					left  = @builder.fcmp(:une, left, ZERO, 'lefttmp')
					right = @builder.fcmp(:une, right, ZERO, 'righttmp')

					int = @builder.and(left, right, 'andtmp')

					@builder.ui2fp(int, RCGTK::DoubleType, 'booltmp')

				else
					right
				end

			when Call
				callee = @module.functions[node.name]

				if not callee
					raise 'Unknown function referenced.'
				end

				if callee.params.size != node.args.length
					raise "Function #{node.name} expected #{callee.params.size} argument(s) but was called with #{node.args.length}."
				end

				args = node.args.map { |arg| translate_expression(arg) }
				@builder.call(callee, *args.push('calltmp'))

			when For
				ph_bb        = @builder.current_block
				fun          = ph_bb.parent
				loop_cond_bb = fun.blocks.append('loop_cond')

				init_val = translate_expression(node.init)
				@builder.br(loop_cond_bb)

				@builder.position_at_end(loop_cond_bb)
				var = @builder.phi(RCGTK::DoubleType, {ph_bb => init_val}, node.var)

				old_var = @st[node.var]
				@st[node.var] = var

				# Translate the conditional code.
				end_cond = translate_expression(node.cond)
				end_cond = @builder.fcmp(:one, end_cond, ZERO, 'loopcond')

				loop_bb0 = fun.blocks.append('loop')
				@builder.position_at_end(loop_bb0)

				translate_expression(node.body)

				loop_bb1 = @builder.current_block

				step_val = translate_expression(node.step)
				next_var = @builder.fadd(var, step_val, 'nextvar')
				var.incoming.add({loop_bb1 => next_var})

				@builder.br(loop_cond_bb)

				# Add the conditional branch to the loop_cond_bb.
				after_bb = fun.blocks.append('afterloop')

				loop_cond_bb.build { cond(end_cond, loop_bb0, after_bb) }

				@builder.position_at_end(after_bb)

				@st[node.var] = old_var

				ZERO

			when If
				cond_value = translate_expression(node.cond)
				cond_value = @builder.fcmp(:one, cond_value, ZERO, 'ifcond')

				start_bb = @builder.current_block
				fun      = start_bb.parent

				then_bb = fun.blocks.append('then')
				@builder.position_at_end(then_bb)
				then_value = translate_expression(node.then)
				new_then_bb = @builder.current_block

				else_bb = fun.blocks.append('else')
				@builder.position_at_end(else_bb)
				else_value = translate_expression(node.else)
				new_else_bb = @builder.current_block

				merge_bb = fun.blocks.append('merge')
				@builder.position_at_end(merge_bb)
				phi = @builder.phi(RCGTK::DoubleType, {new_then_bb => then_value, new_else_bb => else_value}, 'iftmp')

				start_bb.build { cond(cond_value, then_bb, else_bb) }

				new_then_bb.build { br(merge_bb) }
				new_else_bb.build { br(merge_bb) }

				returning(phi) { @builder.position_at_end(merge_bb) }

			when Unary
				op = translate_expression(node.operand)

				case node
				when Neg
					@builder.fneg(op, 'negtmp')

				when Not
					cond = @builder.fcmp(:ueq, op, ZERO, 'cmptmp')
					int  = @builder.not(cond, 'nottmp')
					@builder.ui2fp(int, RCGTK::DoubleType, 'booltmp')
				end

			when Variable
				if @st.key?(node.name)
					@st[node.name]
				else
					raise "Unitialized variable '#{node.name}'."
				end

			when Number
				RCGTK::Double.new(node.value)

			else
				raise 'Unhandled expression type encountered.'
			end
		end

		def translate_function(node)
			# Reset the symbol table.
			@st.clear

			# Translate the function's prototype.
			fun = translate_prototype(node.proto)

			# Create a new basic block to insert into, translate the
			# expression, and set its value as the return value.
			fun.blocks.append('entry', @builder, nil, self) do |jit|
				ret jit.translate_expression(node.body)
			end

			# Verify the function and return it.
			returning(fun) { fun.verify }
		end

		def translate_prototype(node)
			if fun = @module.functions[node.name]
				if fun.blocks.size != 0
					raise "Redefinition of function #{node.name}."
				elsif fun.params.size != node.arg_names.length
					raise "Redefinition of function #{node.name} with different number of arguments."
				end
			else
				fun = @module.functions.add(node.name, RCGTK::DoubleType, Array.new(node.arg_names.length, RCGTK::DoubleType))
			end

			# Name each of the function paramaters.
			returning(fun) do
				node.arg_names.each_with_index do |name, i|
					(@st[name] = fun.params[i]).name = name
				end
			end
		end
	end
end
