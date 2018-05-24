
%code imports %{
  import XRegExp from '@gerhobbelt/xregexp';        // for helping out the `%options xregexp` in the lexer
  import JSON5 from '@gerhobbelt/json5';            // TODO: quick fix until `%code imports` works in the lexer spec!
  import helpers from '../helpers-lib';
  import fs from 'fs';
  import transform from './ebnf-transform';
%}



%start spec

// %parse-param options


/* grammar for parsing jison grammar files */

%{
    var ebnf = false;
%}




%code error_recovery_reduction %{
    // Note:
    //
    // This code section is specifically targetting error recovery handling in the
    // generated parser when the error recovery is unwinding the parse stack to arrive
    // at the targeted error handling production rule.
    //
    // This code is treated like any production rule action code chunk:
    // Special variables `$$`, `$@`, etc. are recognized, while the 'rule terms' can be
    // addressed via `$n` macros as in usual rule actions, only here we DO NOT validate
    // their usefulness as the 'error reduce action' accepts a variable number of
    // production terms (available in `yyrulelength` in case you wish to address the
    // input terms directly in the `yyvstack` and `yylstack` arrays, for instance).
    //
    // This example recovery rule simply collects all parse info stored in the parse
    // stacks and which would otherwise be discarded immediately after this call, thus
    // keeping all parse info details up to the point of actual error RECOVERY available
    // to userland code in the handling 'error rule' in this grammar.
%}


%%


%{
    const OPTION_DOES_NOT_ACCEPT_VALUE = 0x0001;    
    const OPTION_EXPECTS_ONLY_IDENTIFIER_NAMES = 0x0002;
    const OPTION_ALSO_ACCEPTS_STAR_AS_IDENTIFIER_NAME = 0x0004;
    const OPTION_DOES_NOT_ACCEPT_MULTIPLE_OPTIONS = 0x0008;
    const OPTION_DOES_NOT_ACCEPT_COMMA_SEPARATED_OPTIONS = 0x0010;
%}


spec
    : init declaration_list '%%' grammar optional_end_block EOF
        {
            $$ = $declaration_list;
            if ($optional_end_block !== '') {
                yy.addDeclaration($$, { include: $optional_end_block });
            }
            return extend($$, $grammar);
        }
    | init declaration_list '%%' grammar error EOF
        {
            yyerror(rmCommonWS`
                Maybe you did not correctly separate trailing code from the grammar rule set with a '%%' marker on an otherwise empty line?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @grammar)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | init declaration_list error EOF
        {
            yyerror(rmCommonWS`
                Maybe you did not correctly separate the parse 'header section' (token definitions, options, lexer spec, etc.) from the grammar rule set with a '%%' on an otherwise empty line?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @declaration_list)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

// because JISON doesn't support mid-rule actions,
// we set up `yy` using this empty rule at the start:
init
    : ε
        {
            if (!yy.options) yy.options = {};
            yy.__options_flags__ = 0;
            yy.__options_category_description__ = '???';
        }
    ;

optional_end_block
    : ε
        { $$ = ''; }
    | '%%' extra_parser_module_code
        { 
            var srcCode = trimActionCode($extra_parser_module_code);
            if (srcCode) {
                var rv = checkActionBlock(srcCode, @extra_parser_module_code);
                if (rv) {
                    yyerror(rmCommonWS`
                        The extra parser module code section (a.k.a. 'epilogue') does not compile: ${rv}

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@extra_parser_module_code)}
                    `);
                }
                $$ = srcCode; 
            } else {
                $$ = '';
            }
        }
    ;

optional_action_header_block
    : %empty
        { $$ = ''; }
    | optional_action_header_block ACTION_START action ACTION_END
        { 
            var srcCode = trimActionCode($action, $ACTION_START);
            if (srcCode) {
                var rv = checkActionBlock(srcCode, @action);
                if (rv) {
                    yyerror(rmCommonWS`
                        header action code block in the grammar spec production rules section does not compile: ${rv}

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@action)}
                    `);
                }
                $$ = $optional_action_header_block + '\n\n' + srcCode;
            } else {
                $$ = $optional_action_header_block;
            }
        }
    ;

declaration_list
    : declaration_list declaration
        { $$ = $declaration_list; yy.addDeclaration($$, $declaration); }
    | ε
        { $$ = {}; }
    | declaration_list error
        {
            // TODO ...
            yyerror(rmCommonWS`
                declaration list error?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @declaration_list)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

declaration
    : START ID
        { $$ = {start: $ID}; }
    | LEX_BLOCK
        { $$ = {lex: {text: $LEX_BLOCK, position: @LEX_BLOCK}}; }
    | operator
        { $$ = {operator: $operator}; }
    | TOKEN full_token_definitions
        { $$ = {token_list: $full_token_definitions}; }
    | ACTION_START action ACTION_END
        { 
            var srcCode = trimActionCode($action, $ACTION_START);
            var rv = checkActionBlock(srcCode, @action);
            if (rv) {
                yyerror(rmCommonWS`
                    action code block in the grammar spec declaration section does not compile: ${rv}

                      Erroneous area:
                    ${yylexer.prettyPrintRange(@action)}
                `);
            }
            $$ = {include: srcCode}; 
        }
    | parse_params
        { $$ = {parseParams: $parse_params}; }
    | parser_type
        { $$ = {parserType: $parser_type}; }
    | option_keyword option_list OPTIONS_END
        { $$ = {options: $option_list}; }
    | DEBUG
        { $$ = {options: [['debug', true]]}; }
    | EBNF
        {
            ebnf = true; 
            $$ = {options: [['ebnf', true]]}; 
        }
    | UNKNOWN_DECL
        { $$ = {unknownDecl: $UNKNOWN_DECL}; }
    | import_keyword option_list OPTIONS_END
        { 
            // check if there are two unvalued options: 'name path'
            var lst = $option_list;
            var len = lst.length;
            var body;
            if (len === 2 && lst[0][1] === true && lst[1][1] === true) {
                // `name path`:
                body = {
                    name: lst[0][0],
                    path: lst[1][0]
                };
            } else if (len <= 2) {
                yyerror(rmCommonWS`
                    You did not specify a legal qualifier name and/or file path for the '%import' statement, which must have the format:
                        %import qualifier_name file_path

                      Erroneous code:
                    ${yylexer.prettyPrintRange(@option_list, @import_keyword)}
                `);
            } else {
                yyerror(rmCommonWS`
                    You did specify too many attributes for the '%import' statement, which must have the format:
                        %import qualifier_name file_path

                      Erroneous code:
                    ${yylexer.prettyPrintRange(@option_list, @import_keyword)}
                `);
            }

            $$ = {
                type: 'imports', 
                body: body
            }; 
        }
    | import_keyword error
        {
            yyerror(rmCommonWS`
                %import name or source filename missing maybe?

                Note: each '%import' must be qualified by a name, e.g. 'required' before the import path itself:
                    %import qualifier_name file_path

                  Erroneous code:
                ${yylexer.prettyPrintRange(@error, @import_keyword)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | init_code_keyword option_list ACTION_START action ACTION_END OPTIONS_END 
        {
            // check there's only 1 option which is an identifier
            var lst = $option_list;
            var len = lst.length;
            var name;
            if (len === 1 && lst[0][1] === true) {
                // `name`:
                name = lst[0][0];
            } else if (len <= 1) {
                yyerror(rmCommonWS`
                    You did not specify a legal qualifier name for the '%code' initialization code statement, which must have the format:
                        %code qualifier_name %{...code...%}

                      Erroneous code:
                    ${yylexer.prettyPrintRange(@option_list, @init_code_keyword)}
                `);
            } else {
                yyerror(rmCommonWS`
                    You did specify too many attributes for the '%code' initialization code statement, which must have the format:
                        %code qualifier_name %{...code...%}

                      Erroneous code:
                    ${yylexer.prettyPrintRange(@option_list, @init_code_keyword)}
                `);
            }

            var srcCode = trimActionCode($action, $ACTION_START);
            var rv = checkActionBlock(srcCode, @action);
            if (rv) {
                yyerror(rmCommonWS`
                    The '%code ${name}' initialization code section does not compile: ${rv}

                      Erroneous area:
                    ${yylexer.prettyPrintRange(@action, @init_code_keyword)}
                `);
            }
            $$ = {
                type: 'codeSection',
                body: {
                  qualifier: name,
                  include: srcCode
                }
            };
        }
    | init_code_keyword error ACTION_START /* ...action ACTION_END */
        {
            yyerror(rmCommonWS`
                Each '%code' initialization code section must be qualified by a name, e.g. 'required' before the action code itself:
                    %code qualifier_name {action code}

                  Erroneous code:
                ${yylexer.prettyPrintRange(@error, @init_code_keyword)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | START error
        {
            // TODO ...
            yyerror(rmCommonWS`
                %start token error?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @START)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | TOKEN error
        {
            // TODO ...
            yyerror(rmCommonWS`
                %token definition list error?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @TOKEN)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

option_keyword
    : OPTIONS
        {
            yy.__options_flags__ = OPTION_EXPECTS_ONLY_IDENTIFIER_NAMES;
            yy.__options_category_description__ = $OPTIONS;
        }
    ;

import_keyword
    : IMPORT
        {
            yy.__options_flags__ = OPTION_DOES_NOT_ACCEPT_VALUE | OPTION_DOES_NOT_ACCEPT_COMMA_SEPARATED_OPTIONS;
            yy.__options_category_description__ = $IMPORT;
        }
    ;

init_code_keyword
    : CODE
        {
            yy.__options_flags__ = OPTION_DOES_NOT_ACCEPT_VALUE | OPTION_DOES_NOT_ACCEPT_MULTIPLE_OPTIONS | OPTION_DOES_NOT_ACCEPT_COMMA_SEPARATED_OPTIONS;
            yy.__options_category_description__ = $CODE;
        }
    ;

include_keyword
    : INCLUDE
        {
            yy.__options_flags__ = OPTION_DOES_NOT_ACCEPT_VALUE | OPTION_DOES_NOT_ACCEPT_COMMA_SEPARATED_OPTIONS;
            yy.__options_category_description__ = $INCLUDE;
        }
    ;

start_inclusive_keyword
    : START_INC
        {
            yy.__options_flags__ = OPTION_DOES_NOT_ACCEPT_VALUE | OPTION_EXPECTS_ONLY_IDENTIFIER_NAMES;
            yy.__options_category_description__ = 'the inclusive lexer start conditions set (%s)';
        }
    ;

start_exclusive_keyword
    : START_EXC
        {
            yy.__options_flags__ = OPTION_DOES_NOT_ACCEPT_VALUE | OPTION_EXPECTS_ONLY_IDENTIFIER_NAMES;
            yy.__options_category_description__ = 'the exclusive lexer start conditions set (%x)';
        }
    ;

start_conditions_marker
    : '<'
        {
            yy.__options_flags__ = OPTION_DOES_NOT_ACCEPT_VALUE | OPTION_EXPECTS_ONLY_IDENTIFIER_NAMES | OPTION_ALSO_ACCEPTS_STAR_AS_IDENTIFIER_NAME;
            yy.__options_category_description__ = 'the <...> delimited set of lexer start conditions';
        }
    ;

parse_params
    : PARSE_PARAM id_list
        { $$ = $id_list; }
    | PARSE_PARAM error
        {
            // TODO ...
            yyerror(rmCommonWS`
                %parse-params declaration error?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @PARSE_PARAM)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

parser_type
    : PARSER_TYPE symbol
        { $$ = $symbol; }
    | PARSER_TYPE error
        {
            // TODO ...
            yyerror(rmCommonWS`
                %parser-type declaration error?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @PARSER_TYPE)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

operator
    : associativity symbol_list
        { $$ = [$associativity]; $$.push.apply($$, $symbol_list); }
    | associativity error
        {
            // TODO ...
            yyerror(rmCommonWS`
                operator token list error in an associativity statement?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @associativity)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

associativity
    : LEFT
        { $$ = 'left'; }
    | RIGHT
        { $$ = 'right'; }
    | NONASSOC
        { $$ = 'nonassoc'; }
    ;

// As per http://www.gnu.org/software/bison/manual/html_node/Token-Decl.html
full_token_definitions
    : optional_token_type id_list
        {
            var rv = [];
            var lst = $id_list;
            for (var i = 0, len = lst.length; i < len; i++) {
                var id = lst[i];
                var m = {id: id};
                if ($optional_token_type) {
                    m.type = $optional_token_type;
                }
                rv.push(m);
            }
            $$ = rv;
        }
    | optional_token_type one_full_token
        {
            var m = $one_full_token;
            if ($optional_token_type) {
                m.type = $optional_token_type;
            }
            $$ = [m];
        }
    ;

one_full_token
    : ID token_value token_description
        {
            $$ = {
                id: $id,
                value: $token_value,
                description: $token_description
            };
        }
    | ID token_description
        {
            $$ = {
                id: $id,
                description: $token_description
            };
        }
    | ID token_value
        {
            $$ = {
                id: $id,
                value: $token_value
            };
        }
    ;

optional_token_type
    : ε
        { $$ = false; }
    | TOKEN_TYPE
        { $$ = $TOKEN_TYPE; }
    ;

token_value
    : INTEGER
        { $$ = $INTEGER; }
    ;

token_description
    : STRING_LIT
        { $$ = $STRING_LIT; }
    ;

grammar
    : optional_action_header_block production_list
        {
            $$ = {
                grammar: $production_list
            };

            // source code has already been checked!
            var srcCode = $optional_action_header_block;
            if (srcCode) {
                yy.addDeclaration($$, { actionInclude: srcCode });
            }
        }
    ;

production_list
    : production_list production
        {
            $$ = $production_list;
            if ($production[0] in $$) {
                $$[$production[0]] = $$[$production[0]].concat($production[1]);
            } else {
                $$[$production[0]] = $production[1];
            }
        }
    | production
        { $$ = {}; $$[$production[0]] = $production[1]; }
    ;

production
    : production_id handle_list ';'
        {$$ = [$production_id, $handle_list];}
    | production_id error ';'
        {
            // TODO ...
            yyerror(rmCommonWS`
                rule production declaration error?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @production_id)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | production_id error
        {
            // TODO ...
            yyerror(rmCommonWS`
                rule production declaration error: did you terminate the rule production set with a semicolon?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @production_id)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

production_id
    : ID optional_production_description ':'
        {
            $$ = $ID;

            // TODO: carry rule description support into the parser generator...
        }
    | ID optional_production_description error
        {
            // TODO ...
            yyerror(rmCommonWS`
                rule id should be followed by a colon, but that one seems missing?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @ID)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | ID optional_production_description ARROW_ACTION_START
        {
            yyerror(rmCommonWS`
                rule id should be followed by a colon instead of an arrow: 
                please adjust your grammar to use this format:

                    rule_id : terms  { optional action code }
                            | terms  { optional action code }
                            ...
                            ;

                  Erroneous area:
                ${yylexer.prettyPrintRange(@ARROW_ACTION_START, @ID)}
            `);
        }
    ;

optional_production_description
    : STRING_LIT
        { $$ = $STRING_LIT; }
    | ε
    ;

handle_list
    : handle_list '|' handle_action
        {
            $$ = $handle_list;
            $$.push($handle_action);
        }
    | handle_action
        {
            $$ = [$handle_action];
        }
    | handle_list '|' error
        {
            // TODO ...
            yyerror(rmCommonWS`
                rule alternative production declaration error?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @handle_list)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | handle_list ':' error
        {
            // TODO ...
            yyerror(rmCommonWS`
                multiple alternative rule productions should be separated by a '|' pipe character, not a ':' colon!

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @handle_list)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

handle_action
    : handle prec ACTION_START action ACTION_END
        {
            $$ = [($handle.length ? $handle.join(' ') : '')];
            var srcCode = trimActionCode($action, $ACTION_START);
            if (srcCode) {
                var rv = checkActionBlock(srcCode, @action);
                if (rv) {
                    yyerror(rmCommonWS`
                        production rule action code block does not compile: ${rv}

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@action, @handle)}
                    `);
                }
                $$.push(srcCode);
            }

            if ($prec) {
                if ($handle.length === 0) {
                    yyerror(rmCommonWS`
                        You cannot specify a precedence override for an epsilon (a.k.a. empty) rule!

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@handle, @0, @action /* @handle is very probably NULL! We need this one for some decent location info! */)}
                    `);
                }
                $$.push($prec);
            }

            if ($$.length === 1) {
                $$ = $$[0];
            }
        }
    | handle prec ARROW_ACTION_START action ACTION_END
        {
            $$ = [($handle.length ? $handle.join(' ') : '')];

            var srcCode = trimActionCode($action);
            if (srcCode) {
                // add braces around ARROW_ACTION_CODE so that the action chunk test/compiler
                // will uncover any illegal action code following the arrow operator, e.g.
                // multiple statements separated by semicolon.
                //
                // Note/Optimization:
                // there's no need for braces in the generated expression when we can
                // already see the given action is an identifier string or something else
                // that's a sure simple thing for a JavaScript `return` statement to carry.
                // By doing this, we simplify the token return replacement code replacement
                // process which will be applied to the parsed lexer before its code
                // will be generated by JISON.
                if (/^[^\r\n;\/]+$/.test(srcCode)) {
                    srcCode = '$$ = ' + srcCode; 
                } else {
                    srcCode = '$$ = (' + srcCode + '\n)'; 
                }

                var rv = checkActionBlock(srcCode, @action);
                if (rv) {
                    yyerror(rmCommonWS`
                        The lexer rule's 'arrow' action code section does not compile: ${rv}

                        # NOTE that the arrow action automatically wraps the action code
                        # in a \`$$ = (...);\` statement to prevent hard-to-diagnose run-time
                        # errors down the line.

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@action, @handle)}
                    `);
                }

                $$.push(srcCode);
            }
            
            if ($prec) {
                if ($handle.length === 0) {
                    yyerror(rmCommonWS`
                        You cannot specify a precedence override for an epsilon (a.k.a. empty) rule!

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@handle, @0, @action /* @handle is very probably NULL! We need this one for some decent location info! */)}
                    `);
                }
                $$.push($prec);
            }

            if ($$.length === 1) {
                $$ = $$[0];
            }
        }
    | handle prec
        {
            $$ = [($handle.length ? $handle.join(' ') : '')];

            if ($prec) {
                if ($handle.length === 0) {
                    yyerror(rmCommonWS`
                        You cannot specify a precedence override for an epsilon (a.k.a. empty) rule!

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@handle, @0, @-1 /* @handle is very probably NULL! We need this one for some decent location info! */)}
                    `);
                }
                $$.push($prec);
            }

            if ($$.length === 1) {
                $$ = $$[0];
            }
        }
    | EPSILON ACTION_START action ACTION_END
        // %epsilon may only be used to signal this is an empty rule alt;
        // hence it can only occur by itself
        // (with an optional action block, but no alias what-so-ever nor any precedence override).
        {
            $$ = [''];
            var srcCode = trimActionCode($action, $ACTION_START);
            if (srcCode) {
                var rv = checkActionBlock(srcCode, @action);
                if (rv) {
                    yyerror(rmCommonWS`
                        epsilon production rule action code block does not compile: ${rv}

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@action, @EPSILON)}
                    `);
                }
                $$.push(srcCode);
            }

            if ($$.length === 1) {
                $$ = $$[0];
            }
        }
    | EPSILON ARROW_ACTION_START action ACTION_END
        // %epsilon may only be used to signal this is an empty rule alt;
        // hence it can only occur by itself
        // (with an optional action block, but no alias what-so-ever nor any precedence override).
        {
            $$ = [''];
            var srcCode = trimActionCode($action);
            if (srcCode) {
                var rv = checkActionBlock(srcCode, @action);
                if (rv) {
                    yyerror(rmCommonWS`
                        epsilon production arrow rule action code block does not compile: ${rv}

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@action, @EPSILON)}
                    `);
                }
                $$.push(srcCode);
            }

            if ($$.length === 1) {
                $$ = $$[0];
            }
        }
    | EPSILON 
        // %epsilon may only be used to signal this is an empty rule alt;
        // hence it can only occur by itself
        // (with an optional action block, but no alias what-so-ever nor any precedence override).
        {
            $$ = '';
        }
    | /* ε */ DUMMY4 
        // empty rules, which are otherwise identical to %epsilon rules:
        // %epsilon may only be used to signal this is an empty rule alt;
        // hence it can only occur by itself
        // (with an optional action block, but no alias what-so-ever nor any precedence override).
        {
            $$ = '';
        }
    | /* ε */ DUMMY4 ACTION_START action ACTION_END
        // %epsilon may only be used to signal this is an empty rule alt;
        // hence it can only occur by itself
        // (with an optional action block, but no alias what-so-ever nor any precedence override).
        {
            $$ = [''];
            var srcCode = trimActionCode($action, $ACTION_START);
            if (srcCode) {
                var rv = checkActionBlock(srcCode, @action);
                if (rv) {
                    yyerror(rmCommonWS`
                        epsilon production rule action code block does not compile: ${rv}

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@action, @ACTION_START)}
                    `);
                }
                $$.push(srcCode);
            }

            if ($$.length === 1) {
                $$ = $$[0];
            }
        }
    | /* ε */ DUMMY4 ARROW_ACTION_START /* action ACTION_END */
        // empty rules, which are otherwise identical to %epsilon rules, MUST NOT contain arrow actions.
        {
            yyerror(rmCommonWS`
                Empty (~ epsilon) rule productions MAY NOT contain arrow action code blocks.
                Only regular '%{...%}' action blocks are allowed here.

                  Erroneous area:
                ${yylexer.prettyPrintRange(@ARROW_ACTION_START)}
            `);
        }
    | DUMMY3 EPSILON ARROW_ACTION_START error
        {
            $$ = [$regex, $error];
            yyerror(rmCommonWS`
                An epsilon production rule action arrow must be followed by a single JavaScript expression to assign the production rule's value, e.g.:

                    rule: %epsilon   -> 42
                        ;

                which is equivalent to:

                    rule: %epsilon   %{ $$ = 42; %}
                        ;

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @ARROW_ACTION_START)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | DUMMY3 EPSILON ACTION_START error /* ACTION_END */
        {
            // TODO: REWRITE
            $$ = [$regex, $error];
            yyerror(rmCommonWS`
                An epsilon production rule action must consist of a (properly '%{...%}' delimited) JavaScript statement block, e.g.:

                    rule: %epsilon   %{ $$ = 'BUGGABOO'; %}

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @EPSILON)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | DUMMY3 EPSILON error
        {
            // TODO ...
            yyerror(rmCommonWS`
                %epsilon rule action declaration error?

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @EPSILON)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

handle
    : handle suffixed_expression
        {
            $$ = $handle;
            $$.push($suffixed_expression);
        }
    | ε
        {
            $$ = [];
        }
    ;

handle_sublist
    : handle_sublist '|' handle
        {
            $$ = $handle_sublist;
            $$.push($handle.join(' '));
        }
    | handle
        {
            $$ = [$handle.join(' ')];
        }
    ;

suffixed_expression
    : expression suffix ALIAS
        {
            $$ = $expression + $suffix + "[" + $ALIAS + "]";
        }
    | expression suffix
        {
            $$ = $expression + $suffix;
        }
    ;

expression
    : symbol
        {
            $$ = $symbol;
        }
    | EOF_ID
        {
            $$ = '$end';
        }
    | '(' handle_sublist ')'
        %{
            // Do not allow empty sublist here, i.e. writing '()' in a grammar is illegal.
            //
            // empty list ε is encoded as `[[]]`:
            var lst = $handle_sublist;
            if (lst.length === 1 && lst[0].length === 0) {
                yyerror(rmCommonWS`
                    Empty grammar rule sublists are not accepted within '( ... )' brackets.

                      Erroneous area:
                    ${yylexer.prettyPrintRange(@$) /* @$ =?= yylexer.deriveLocationInfo(@1, @3) */}
                `);
            }

            $$ = '(' + $handle_sublist.join(' | ') + ')';
        %}
    | '(' handle_sublist error
        {
            yyerror(rmCommonWS`
                Seems you did not correctly bracket a grammar rule sublist in '( ... )' brackets.

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @1)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

suffix
    : ε
        { $$ = ''; }
    | '*'
        { $$ = $1; }
    | '?'
        { $$ = $1; }
    | '+'
        { $$ = $1; }
    ;

prec
    : PREC symbol
        {
            $$ = { prec: $symbol };
        }
    | PREC error
        {
            // TODO ...
            yyerror(rmCommonWS`
                %prec precedence override declaration error?

                  Erroneous precedence declaration:
                ${yylexer.prettyPrintRange(@error, @PREC)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | ε
        {
            $$ = null;
        }
    ;

symbol_list
    : symbol_list symbol
        { $$ = $symbol_list; $$.push($symbol); }
    | symbol
        { $$ = [$symbol]; }
    ;

symbol
    : ID
        { $$ = $ID; }
    | STRING_LIT
        // Re-encode the string *anyway* as it will
        // be made part of the rule rhs a.k.a. production (type: *string*) again and we want
        // to be able to handle all tokens, including *significant space*
        // encoded as literal tokens in a grammar such as this: `rule: A ' ' B`.
        //
        // We also want to detect whether it was a *literal string* ID or a direct ID that 
        // serves as a symbol anywhere else. That way, we can potentially cope with 'nasty' 
        // lexer/parser constructs such as 
        //
        //      %token 'N'
        //      %token N
        //
        //      rule: N 'N' N;
        //
        { $$ = $STRING_LIT; }
    ;

id_list
    : id_list ID
        { $$ = $id_list; $$.push($ID); }
    | ID
        { $$ = [$ID]; }
    ;

action
    : action ACTION
        { $$ = $action + '\n\n' + $ACTION + '\n\n'; }
    | action ACTION_BODY
        { $$ = $action + $ACTION_BODY; }
    | action include_macro_code
        { $$ = $action + '\n\n' + $include_macro_code + '\n\n'; }
    | action INCLUDE_PLACEMENT_ERROR
        {
            yyerror(rmCommonWS`
                You may place the '%include' instruction only at the start/front of a line.

                  Its use is not permitted at this position:
                ${yylexer.prettyPrintRange(@INCLUDE_PLACEMENT_ERROR, @-1)}
            `);
        }
    | action BRACKET_MISSING
        {
            yyerror(rmCommonWS`
                Missing curly braces: seems you did not correctly bracket a lexer rule action block in curly braces: '{ ... }'.

                  Offending action body:
                ${yylexer.prettyPrintRange(@BRACKET_MISSING, @-1)}
            `);
        }
    | action BRACKET_SURPLUS
        {
            yyerror(rmCommonWS`
                Too many curly braces: seems you did not correctly bracket a lexer rule action block in curly braces: '{ ... }'.

                  Offending action body:
                ${yylexer.prettyPrintRange(@BRACKET_SURPLUS, @-1)}
            `);
        }
    | action UNTERMINATED_STRING_ERROR
        {
            yyerror(rmCommonWS`
                Unterminated string constant in lexer rule action block.

                When your action code is as intended, it may help to enclose 
                your rule action block code in a '%{...%}' block.

                  Offending action body:
                ${yylexer.prettyPrintRange(@UNTERMINATED_STRING_ERROR, @-1)}
            `);
        }
    | ε
        { $$ = ''; }
    ;


option_list
    : option_list ','[comma] option 
        { 
            // validate that this is legal behaviour under the given circumstances, i.e. parser context:
            if (yy.__options_flags__ & OPTION_DOES_NOT_ACCEPT_MULTIPLE_OPTIONS) {
                yyerror(rmCommonWS`
                    You may only specify one name/argument in a ${yy.__options_category_description__} statement.

                      Erroneous area:
                    ${yylexer.prettyPrintRange(yylexer.deriveLocationInfo(@comma, @option), @-1)}
                `);
            }
            if (yy.__options_flags__ & OPTION_DOES_NOT_ACCEPT_COMMA_SEPARATED_OPTIONS) {
                var optlist = $option_list.map(function (opt) { 
                    return opt[0]; 
                });
                optlist.push($option[0]);

                yyerror(rmCommonWS`
                    You may not separate entries in a ${yy.__options_category_description__} statement using commas.
                    Use whitespace instead, e.g.:

                        ${$-1} ${optlist.join(' ')} ...

                      Erroneous area:
                    ${yylexer.prettyPrintRange(yylexer.deriveLocationInfo(@comma, @option_list), @-1)}
                `);
            }
            $$ = $option_list; 
            $$.push($option); 
        }
    | option_list option 
        { 
            // validate that this is legal behaviour under the given circumstances, i.e. parser context:
            if (yy.__options_flags__ & OPTION_DOES_NOT_ACCEPT_MULTIPLE_OPTIONS) {
                yyerror(rmCommonWS`
                    You may only specify one name/argument in a ${yy.__options_category_description__} statement.

                      Erroneous area:
                    ${yylexer.prettyPrintRange(yylexer.deriveLocationInfo(@option), @-1)}
                `);
            }
            $$ = $option_list; 
            $$.push($option); 
        }
    | option
        { 
            $$ = [$option]; 
        }
    ;

option
    : option_name
        { 
            $$ = [$option_name, true]; 
        }
    | option_name '=' option_value
        {
            // validate that this is legal behaviour under the given circumstances, i.e. parser context:
            if (yy.__options_flags__ & OPTION_DOES_NOT_ACCEPT_VALUE) {
                yyerror(rmCommonWS`
                    The entries in a ${yy.__options_category_description__} statement MUST NOT be assigned values, such as '${$option_name}=${$option_value}'.

                      Erroneous area:
                    ${yylexer.prettyPrintRange(yylexer.deriveLocationInfo(@option_value, @option_name), @-1)}
                `);
            }
            $$ = [$option_name, $option_value]; 
        }
    | option_name '=' error
        {
            // TODO ...
            yyerror(rmCommonWS`
                Internal error: option "${$option}" value assignment failure in a ${yy.__options_category_description__} statement.

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @-1)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    | DUMMY3 error
        {
            var with_value_msg = ' (with optional value assignment)';
            if (yy.__options_flags__ & OPTION_DOES_NOT_ACCEPT_VALUE) {
                with_value_msg = '';
            }
            yyerror(rmCommonWS`
                Expected a valid option name${with_value_msg} in a ${yy.__options_category_description__} statement.

                  Erroneous area:
                ${yylexer.prettyPrintRange(@error, @-1)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

option_name
    : option_value[name]
        { 
            // validate that this is legal input under the given circumstances, i.e. parser context:
            if (yy.__options_flags__ & OPTION_EXPECTS_ONLY_IDENTIFIER_NAMES) {
                $$ = mkIdentifier($name);
                // check if the transformation is obvious & trivial to humans;
                // if not, report an error as we don't want confusion due to
                // typos and/or garbage input here producing something that
                // is usable from a machine perspective.
                if (!isLegalIdentifierInput($name)) {
                    var with_value_msg = ' (with optional value assignment)';
                    if (yy.__options_flags__ & OPTION_DOES_NOT_ACCEPT_VALUE) {
                        with_value_msg = '';
                    }
                    yyerror(rmCommonWS`
                        Expected a valid name/argument${with_value_msg} in a ${yy.__options_category_description__} statement.
                        Entries (names) must look like regular programming language
                        identifiers, with the addition that option names MAY contain
                        '-' dashes, e.g. 'example-option-1'.

                          Erroneous area:
                        ${yylexer.prettyPrintRange(@name, @-1)}
                    `);
                }
            } else {
                $$ = $name;
            }
        }
    | '*'[star]
        { 
            // validate that this is legal input under the given circumstances, i.e. parser context:
            if (!(yy.__options_flags__ & OPTION_EXPECTS_ONLY_IDENTIFIER_NAMES) || (yy.__options_flags__ & OPTION_ALSO_ACCEPTS_STAR_AS_IDENTIFIER_NAME)) {
                $$ = $star;
            } else {
                var with_value_msg = ' (with optional value assignment)';
                if (yy.__options_flags__ & OPTION_DOES_NOT_ACCEPT_VALUE) {
                    with_value_msg = '';
                }
                yyerror(rmCommonWS`
                    Expected a valid name/argument${with_value_msg} in a ${yy.__options_category_description__} statement.
                    Entries (names) must look like regular programming language
                    identifiers, with the addition that option names MAY contain
                    '-' dashes, e.g. 'example-option-1'

                      Erroneous area:
                    ${yylexer.prettyPrintRange(@star, @-1)}
                `);
            }
        }
    ;

option_value
    : OPTION_STRING
        { $$ = JSON5.parse($OPTION_STRING); }
    | OPTION_VALUE
        { $$ = parseValue($OPTION_VALUE); }
    ;

extra_parser_module_code
    : optional_module_code_chunk
        {
            $$ = $optional_module_code_chunk;
        }
    | extra_parser_module_code ACTION_START include_macro_code ACTION_END optional_module_code_chunk
        {
            $$ = $extra_lexer_module_code + '\n\n' + $include_macro_code + '\n\n' + $optional_module_code_chunk;
        }
    ;

include_macro_code
    : include_keyword option_list OPTIONS_END
        {
            // check if there is only 1 unvalued options: 'path'
            var lst = $option_list;
            var len = lst.length;
            var path;
            if (len === 1 && lst[0][1] === true) {
                // `path`:
                path = lst[0][0];
            } else if (len <= 1) {
                yyerror(rmCommonWS`
                    You did not specify a legal file path for the '%include' statement, which must have the format:
                        %include file_path

                      Erroneous code:
                    ${yylexer.prettyPrintRange(@option_list, @include_keyword)}

                      Technical error report:
                    ${$error.errStr}
                `);
            } else {
                yyerror(rmCommonWS`
                    You did specify too many attributes for the '%include' statement, which must have the format:
                        %include file_path

                      Erroneous code:
                    ${yylexer.prettyPrintRange(@option_list, @include_keyword)}

                      Technical error report:
                    ${$error.errStr}
                `);
            }

            var fileContent = fs.readFileSync(path, { encoding: 'utf-8' });
            // And no, we don't support nested '%include'!
            $$ = '\n// Included by Jison: ' + path + ':\n\n' + fileContent + '\n\n// End Of Include by Jison: ' + path + '\n\n';
        }
    | include_keyword error
        {
            yyerror(rmCommonWS`
                %include MUST be followed by a valid file path.

                  Erroneous path:
                ${yylexer.prettyPrintRange(@error, @include_keyword)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

module_code_chunk
    : TRAILING_CODE_CHUNK
        { $$ = $TRAILING_CODE_CHUNK; }
    | module_code_chunk TRAILING_CODE_CHUNK
        { $$ = $module_code_chunk + $TRAILING_CODE_CHUNK; }
    | error TRAILING_CODE_CHUNK
        {
            // TODO ...
            yyerror(rmCommonWS`
                Module code declaration error?

                  Erroneous code:
                ${yylexer.prettyPrintRange(@error)}

                  Technical error report:
                ${$error.errStr}
            `);
        }
    ;

optional_module_code_chunk
    : module_code_chunk
        { $$ = $module_code_chunk; }
    | ε
        { $$ = ''; }
    ;

%%


var rmCommonWS = helpers.rmCommonWS;
var dquote = helpers.dquote;
var checkActionBlock = helpers.checkActionBlock;
var mkIdentifier = helpers.mkIdentifier;
var isLegalIdentifierInput = helpers.isLegalIdentifierInput;
var trimActionCode = helpers.trimActionCode;


// transform ebnf to bnf if necessary
function extend(json, grammar) {
    if (ebnf) {
        json.ebnf = grammar.grammar;        // keep the original source EBNF around for possible pretty-printing & AST exports.
        json.bnf = transform(grammar.grammar);
    }
    else {
        json.bnf = grammar.grammar;
    }
    if (grammar.actionInclude) {
        json.actionInclude = grammar.actionInclude;
    }
    return json;
}


// convert string value to number or boolean value, when possible
// (and when this is more or less obviously the intent)
// otherwise produce the string itself as value.
function parseValue(v) {
    if (v === 'false') {
        return false;
    }
    if (v === 'true') {
        return true;
    }
    // http://stackoverflow.com/questions/175739/is-there-a-built-in-way-in-javascript-to-check-if-a-string-is-a-valid-number
    // Note that the `v` check ensures that we do not convert `undefined`, `null` and `''` (empty string!)
    if (v && !isNaN(v)) {
        var rv = +v;
        if (isFinite(rv)) {
            return rv;
        }
    }
    return v;
}


parser.warn = function p_warn() {
    console.warn.apply(console, arguments);
};

parser.log = function p_log() {
    console.log.apply(console, arguments);
};

