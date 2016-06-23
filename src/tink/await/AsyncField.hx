package tink.await;

import haxe.macro.Context;
import haxe.macro.Expr;
import tink.await.MacroTools.*;
import tink.await.Await.*;

using tink.CoreApi;
using tink.MacroApi;
using Lambda;
using tink.await.MacroTools.MacroExprTools;

typedef AsyncContext = {
	?catcher: String,
	?loop: String,
	needsResult: Bool,
	asyncReturn: Bool
}

class AsyncField {
	
	#if tink_await_cache
	// TODO: this may lead to potential memory leak? if the compilation server has run long enough...
	static var cache = new Map<String, Function>();
	#end
	
	var func: Function;
	var expr: Expr;
	var asyncReturn: Bool;
	
	public function new(func: Function, asyncReturn: Bool) {
		this.func = func;
		expr = func.expr;
		this.asyncReturn = asyncReturn;
	}
	
	public function transform(): Function {
		#if tink_await_cache
		var signature = Context.signature(expr);
		if(cache.exists(signature))
			return cache.get(signature);
		#end
		var unknown = expr.pos.makeBlankType();
		var type = func.ret == null ? unknown : func.ret;
		var err = (macro: Dynamic);
		var result = {
			args: func.args,
			params: func.params,
			ret: !asyncReturn || func.ret == null ? func.ret : (macro: tink.core.Future<tink.core.Outcome<$type, $err>>),
			expr: 
				if (asyncReturn)
					macro @:pos(expr.pos)
						return tink.core.Future.async(function(__return) 
							#if await_catch_none
							${process(expr, {asyncReturn: true, needsResult: false}, function(e) return e)}
							#else
							try ${process(expr, {asyncReturn: true, needsResult: false}, function(e) return e)}
							catch(e: Dynamic) ${catchCall(null, expr.pos)}
							#end
						)
				else
					process(expr, {asyncReturn: false, needsResult: false}, function(e) return e)
		};
		#if tink_await_cache
		cache.set(signature, result);
		#end
		return result;
	}	
		
	function hasAwait(?el: Array<Expr>, ?e: Expr): Bool {
		if (el != null) {
			for (e in el)
				if (hasAwait(e)) 
					return true;
			return false;
		}
		if (e == null) return false;
		switch e.expr {
			case EMeta(m, em) if (isAwait(m.name)):
				return true;
			default:
				var await = false;
				e.iter(function(e) if (hasAwait(e)) await = true);
				return await;
		}
	}
		
	function catchCall(catcher: Null<String>, pos: Position)
		return 
			if (catcher == null) 
				macro @:pos(pos) __return(tink.core.Outcome.Failure(e))
			else 
				catcher.resolve().call([macro @:pos(pos) e]);
		
	function handler(tmp: String, ctx: AsyncContext, next: Expr -> Expr): Expr {
		var catchErr = catchCall(ctx.catcher, Context.currentPos());
		var fail = ctx.asyncReturn
			? catchErr
			: macro throw e;
		var result = tmp+'_result';
		var body = macro {
			var $result;
			switch tink.await.OutcomeTools.getOutcome(${tmp.resolve()}) {
				case Success(v): $i{result} = v;
				case Failure(e): $fail; return;
			}
			${next(result.resolve())}
		};
		#if !await_catch_none
		if (ctx.asyncReturn || ctx.catcher != null)
			body = macro @:pos(body.pos)
				try $body 
				catch(e: Dynamic) ${catchCall(ctx.catcher, body.pos)};
		#end
		return body.func([tmp.toArg()], false).asExpr();
	}
	
	function transformObj<T: {expr: Expr}>(ol: Array<T>, ctx: AsyncContext, final: Array<T> -> Expr): Expr {
		var el = ol.map(function(v) return v.expr);
		return transformList(el, ctx, function(transformedEl: Array<Expr>){
			return final({
				var i = 0;
				ol.map(function(v) {
					var obj = Reflect.copy(v);
					obj.expr = transformedEl[i++];
					return obj;
				});
			});
		});
	}
	
	function transformList(el: Array<Expr>, ctx: AsyncContext, final: Array<Expr> -> Expr): Expr {
		function transformNext(i: Int, transformedEl: Array<Expr>): Expr {
			if (i == el.length)
				return final(transformedEl);
			if (el[i] == null) {
				transformedEl.push(null);
				return transformNext(i + 1, transformedEl);
			}
			return process(el[i], ctx, function(transformed: Expr): Expr {
				transformedEl.push(transformed);
				return transformNext(i + 1, transformedEl);
			});
		}
		
		return transformNext(0, []);
	}
	
	function processControl(e: Expr, ctx: AsyncContext): Expr {
		if (e == null) return null;
		switch e.expr {
			case null: return null;
			case EReturn(e1): 
				return macro @:pos(e.pos)
					return __return(tink.core.Outcome.Success($e1));
			case EThrow(e1): 
				return
					if (ctx.catcher != null)
						macro @:pos(e.pos)
							return ${ctx.catcher.resolve()}($e1)
					else if (ctx.asyncReturn)
						macro @:pos(e.pos)
							return __return(tink.core.Outcome.Failure($e1))
					else
						macro @:pos(e.pos)
							throw $e1
				;
			case EBreak if(ctx.loop != null):
				return macro @:pos(e.pos)
					return ${breakName(ctx.loop).resolve()}();
			case EContinue if(ctx.loop != null):
				return macro @:pos(e.pos)
					return ${continueName(ctx.loop).resolve()}();
			case EFunction(_,_): return e;
			default: return e.map(processControl.bind(_, ctx));
		}
	}
	
	function continueName(loop) return loop+'_continue';
	function breakName(loop) return loop+'_break';
		
	function process(e: Expr, ctx: AsyncContext, next: Expr -> Expr): Expr {
		ctx = Reflect.copy(ctx);
		
		switch e.expr {
			case EBlock(el):
				var needsResult = ctx.needsResult;
				ctx.needsResult = false;
				if (el.length == 0) return next(emptyExpr());
				function line(i:Int): Expr {
					if (i == el.length - 1) {
						ctx.needsResult = needsResult;
						return process(el[i], ctx, next);
					}
					
					return process(el[i], ctx, function(transformed: Expr) {
						var response = [transformed];
						response.push(line(i+1));
						return bundle(response);
				  });
				}
				return line(0);
			case EMeta(m, {expr: EFunction(name, f), pos: pos}) if (isAsync(m.name)):
				return next(EFunction(name, new AsyncField(f, true).transform()).at(pos));
			case EMeta(m, {expr: EFunction(name, f), pos: pos}) if (isAwait(m.name)):
				return next(EFunction(name, new AsyncField(f, false).transform()).at(pos));
			case EMeta(m, em) if (isAwait(m.name)):
				var tmp = tmpVar();
				return process(em, ctx, function(transformed)
					return macro @:pos(em.pos)
						$transformed.handle(${handler(tmp, ctx, next)})
				);
			case EFor(it, expr):
				if (!hasAwait(expr)) {
					ctx.loop = null;
					ctx.needsResult = false;
					return process(it, ctx, function(transformed)
						return next(EFor(transformed, processControl(expr, ctx)).at(e.pos))
					);
				}
				switch it.expr {
					case EIn(e1, e2):
						var ident = e1.getIdent().sure();
						var blank = e2.pos.makeBlankType();
						var iteratorBody = macro @:pos(e2.pos) ($e2: tink.await.LoopIterator<$blank>);
						ctx.needsResult = false;
						var body = process(macro while(__iterator.hasNext()) {
							var $ident = __iterator.next();
							$expr;
						}, ctx, next);
						return macro @:pos(e.pos) {var __iterator = $iteratorBody; $body;};
					default:
				}
			case EWhile(econd, e1, normalWhile):
				if (!hasAwait(e1)) {
					ctx.loop = null;
					ctx.needsResult = false;
					return process(econd, ctx, function(tcond)
						return next(EWhile(tcond, processControl(e1, ctx), normalWhile).at(e.pos))
					);
				}
				var loop = tmpVar();
				ctx.needsResult = false;
				ctx.loop = loop;
				var breakI = breakName(loop), continueI = continueName(loop);
				var doBody = process(e1, ctx, function(transformed) 
					return bundle([transformed, continueName(loop).resolve().call()])
				);
				ctx.needsResult = true;
				var continueBody = process(econd, ctx, function(transformed)
					return EIf(transformed, macro __do(), breakName(loop).resolve().call()).at(econd.pos)
				);
				var breakBody = next(emptyExpr());
				if (normalWhile)
					return macro @:pos(e.pos) {
						var __doCount = 0;
						function $breakI() $breakBody;
						function $continueI() {
							function __do() {
								if (__doCount++ == 0)
									do $doBody
									while (--__doCount != 0);
							}
							$continueBody;
						}
						${continueI.resolve()}();
					};
				else
					return macro @:pos(e.pos) {
						var __doCount = 0;
						function $breakI() $breakBody;
						function __do() {
							function $continueI() $continueBody;
							if (__doCount++ == 0)
								do $doBody
								while (--__doCount != 0);
						}
						__do();
					};
			case EBreak:
				return macro @:pos(e.pos) return ${breakName(ctx.loop).resolve()}();
			case EContinue:
				return macro @:pos(e.pos) return ${continueName(ctx.loop).resolve()}();
			case ETry(e1, catches):
				var wrapper = new AsyncWrapper(ctx, next);
				var name = tmpVar();
				ctx.catcher = null;
				var transformedCatches = [
					for (c in catches)
						{type: c.type, name: c.name, expr: c.expr == null ? null : process(c.expr, ctx, wrapper.invocation)}
				];
				var body = ETry(macro throw e, transformedCatches).at(e.pos);
				var func = body.func(['e'.toArg()]);
				var declaration = EFunction(name, func).at(e.pos);
				ctx.catcher = name;
				var call = name.resolve().call(['e'.resolve()]);
				var entry = process(e1, ctx, wrapper.invocation);
				entry = macro @:pos(e.pos)
					try $entry catch(e: Dynamic) $call;
				return bundle([wrapper.declaration, declaration, entry]);
			case EReturn(e1):
				ctx.needsResult = true;
				if (!ctx.asyncReturn)
					Context.error('Cannot return in @await field', e.pos);
				return process(e1, ctx, function(transformed)
					return macro @:pos(e.pos)
						return __return(tink.core.Outcome.Success($transformed))
				);
			case EThrow(e1):
				ctx.needsResult = true;
				return
					if (ctx.catcher != null)
						process(e1, ctx, function(transformed)
							return macro @:pos(e.pos)
								return ${ctx.catcher.resolve()}($transformed)
						);
					else if (ctx.asyncReturn)
						process(e1, ctx, function(transformed)
							return macro @:pos(e.pos)
								return __return(tink.core.Outcome.Failure($transformed))
						);
					else
						process(e1, ctx, function(transformed)
							return macro @:pos(e.pos)
								throw $transformed
						);
			case ETernary(econd, eif, eelse) |
				 EIf (econd, eif, eelse):
				if (!hasAwait([eif, eelse])) {
					return process(econd, ctx, function(tcond)
						return next(EIf(tcond, processControl(eif, ctx), processControl(eelse, ctx)).at(e.pos))
					);
				}
				var wrapper = new AsyncWrapper(ctx, next);
				return process(econd, ctx, function(transformed) {
					var entry = EIf(
						transformed,
						process(eif, ctx, wrapper.invocation),
						eelse == null ? wrapper.invocation(emptyExpr()) : process(eelse, ctx, wrapper.invocation)
					).at(e.pos);
					return bundle([wrapper.declaration, entry]);
				});
			case ESwitch(e1, cases, edef):
				if (!hasAwait(e))
					return next(processControl(e, ctx));
				var wrapper = new AsyncWrapper(ctx, next);
				return process(e1, ctx, function(transformed) {
					var transformedCases = [
						for (c in cases)
							if (c.expr == null) {
								if (ctx.needsResult) Context.error('Case '+c.guard+' needs a return value', e1.pos);
								{expr: wrapper.invocation(emptyExpr()).at(e1.pos), guard: c.guard, values: c.values}
							}
							else {expr: process(c.expr, ctx, wrapper.invocation).at(c.expr.pos), guard: c.guard, values: c.values}
					];
					var transformedDefault = switch edef {
						case null: null;
						case def if (def.expr == null): 
							if (ctx.needsResult) Context.error('Default case needs a return value', e1.pos);
							wrapper.invocation(emptyExpr()).at(e1.pos);
						default: process(edef, ctx, wrapper.invocation).at(e1.pos);
					}
					var entry = ESwitch(transformed, transformedCases, transformedDefault).at(e.pos);
					return bundle([wrapper.declaration, entry]);
				});
			case EObjectDecl(obj):
				ctx.needsResult = true;
				return transformObj(obj, ctx, function(transformedObjs)
					return next(EObjectDecl(transformedObjs).at(e.pos))
				);
			case EVars(obj):
				ctx.needsResult = true;
				return transformObj(obj, ctx, function(transformedObjs)
					return next(EVars(transformedObjs).at(e.pos))
				);
			case EUntyped(e1):
				return process(e1, ctx, function(transformed)
					return next(EUntyped(transformed).at(e.pos))
				);
			case ECast(e1, t):
				ctx.needsResult = true;
				return process(e1, ctx, function(transformed)
					return next(ECast(transformed, t).at(e.pos))
				);
			case EBinop(op, e1, e2):
				ctx.needsResult = true;
				return process(e1, ctx, function(t1)
					return process(e2, ctx, function(t2)
						return next(EBinop(op, t1, t2).at(e.pos))
					)
				);
			case EParenthesis(e1):
				return process(e1, ctx, function(t1)
					return next(EParenthesis(t1).at(e.pos))
				);
			case EArray(e1, e2):
				ctx.needsResult = true;
				return process(e1, ctx, function(t1)
					return process(e2, ctx, function(t2)
						return next(EArray(t1, t2).at(e.pos))
					)
				);
			case EUnop(op, postFix, e1):
				ctx.needsResult = true;
				return process(e1, ctx, function(transformed)
					return next(EUnop(op, postFix, transformed).at(e.pos))
				);
			case EField(e1, field):
				ctx.needsResult = true;
				return process(e1, ctx, function(transformed)
					return next(EField(transformed, field).at(e.pos))
				);
			case ECheckType(e1, t):
				ctx.needsResult = true;
				return process(e1, ctx, function(transformed)
					return next(ECheckType(transformed, t).at(e.pos))
				);
			case EArrayDecl(params):
				ctx.needsResult = true;
				return transformList(params, ctx, function(transformedParameters: Array<Expr>)
					return next(EArrayDecl(transformedParameters).at(e.pos))
				);
			case ECall(e1, params):
				ctx.needsResult = true;
				return transformList(params, ctx, function(transformedParameters: Array<Expr>)
					return process(e1, ctx, function(transformed) 
						return next(ECall(transformed, transformedParameters).at(e.pos))
					)
				);
			case ENew(t, params):
				ctx.needsResult = true;
				return transformList(params, ctx, function(transformedParameters: Array<Expr>)
					return next(ENew(t, transformedParameters).at(e.pos))
				);
			default:
		}
		return unpack(next(e));
	}
	
}

class AsyncWrapper {
	
	public var declaration(default, null): Expr;
	var ctx: AsyncContext;
	var functionName: String;
	var argName: String;
	var empty: Bool = false;
	
	public function new(ctx: AsyncContext, next: Expr -> Expr) {
		this.ctx = ctx;
		functionName = tmpVar();
		argName = tmpVar();
		var func;
		if (ctx.needsResult) {
			func = next(argName.resolve()).func([argName.toArg()], false);
		} else {
			var body = next(emptyExpr());
			switch body.expr {
				case EBlock([]): 
					empty = true;
					declaration = emptyExpr();
					return;
				default:
			}
			func = body.func(false);
		}
		declaration = EFunction(functionName, func).at();
	}
	
	public function invocation(transformed: Expr): Expr {
		if (empty)
			return transformed;
		if (ctx.needsResult)
			return functionName.resolve().call([transformed]);
		return bundle([transformed, functionName.resolve().call()]);
	}
	
}