#include <iostream>
#include <string>
#include <vector>
#include <exception>

#include "edn_parser.h"

//
// EDN spec at: https://github.com/edn-format/edn
//
//
// many thanks to Florian Frank for json-ruby which was essential in
// helping me learn about ragel
//

%%{
        machine EDN_common;

        cr             = '\n';
        counter        = ( cr @{ line_number++; } );
        cr_neg         = [^\n];
        ws             = [\t\v\f\r ] | ',' | counter;
        comment        = ';' cr_neg* counter;
        ignore         = ws | comment;

        operators      = [/\.\*!_\?$%&<>\=+\-\'];

        begin_dispatch = '#';
        begin_keyword  = ':';
        begin_char     = '\\';
        begin_vector   = '[';
        begin_map      = '{';
        begin_list     = '(';
        begin_meta     = '^';
        string_delim   = '"';
        begin_number   = digit;
        begin_value    = alnum | [:\"\{\[\(\\\#^] | operators;
        begin_symbol   = alpha;

        # int / decimal rules
        integer        = ('0' | [1-9] digit*);
        exp            = ([Ee] [+\-]? digit+);


        # common actions
        action close_err {
            std::stringstream s;
            s << "unterminated " << EDN_TYPE;
            error(__FUNCTION__, s.str());
            // need these?
            fhold; fbreak;
        }

        action exit { fhold; fbreak; }
}%%

// ============================================================
// machine for parsing various EDN token types
//

%%{
    machine EDN_value;
    include EDN_common;

    write data;

    action parse_string {
        // string types within double-quotes
        const char *np = parse_string(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_keyword {
        // tokens with a leading ':'
        const char *np = parse_keyword(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_number {
        // tokens w/ leading digits: non-negative integers & decimals.
        // try to parse a decimal first
        const char *np = parse_decimal(fpc, pe, v);
        if (np == NULL) {
            // if we can't, try to parse it as an int
            np = parse_integer(fpc, pe, v);
        }

        if (np) {
            fexec np;
            fhold;
            fbreak;
        }
        else {
            error(__FUNCTION__, *p);
            fexec pe;
        }
    }

    action parse_operator {
        // stand-alone operators *, +, -, etc.
        const char *np = parse_operator(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_char {
        // tokens w/ leading \ (escaped characters \newline, \c, etc.)
        const char *np = parse_esc_char(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_symbol {
        // user identifiers and reserved keywords (true, false, nil)
        VALUE sym = Qnil;
        const char *np = parse_symbol(fpc, pe, sym);
        if (np == NULL) { fhold; fbreak; } else {
            // parse_symbol will make 'sym' a ruby string
            if      (std::strcmp(RSTRING_PTR(sym), "true") == 0)  { v = Qtrue; }
            else if (std::strcmp(RSTRING_PTR(sym), "false") == 0) { v = Qfalse; }
            else if (std::strcmp(RSTRING_PTR(sym), "nil") == 0)   { v = Qnil; }
            else {
                v = Parser::make_edn_symbol(sym);
            }
            fexec np;
        }
    }

    action parse_vector {
        // [
        const char *np = parse_vector(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_list {
        // (
        const char *np = parse_list(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_map {
        // {
        const char *np = parse_map(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_meta {
        // ^
        const char *np = parse_meta(fpc, pe);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_dispatch {
        // handles tokens w/ leading # ("#_", "#{", and tagged elems)
        const char *np = parse_dispatch(fpc + 1, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }


    main := (
             string_delim >parse_string |
             begin_keyword >parse_keyword |
             begin_number >parse_number |
             operators >parse_operator |
             begin_char >parse_char |
             begin_symbol >parse_symbol |
             begin_vector >parse_vector |
             begin_list >parse_list |
             begin_map >parse_map |
             begin_meta >parse_meta |
             begin_dispatch >parse_dispatch
            ) %*exit;
}%%


const char *edn::Parser::parse_value(const char *p, const char *pe, VALUE& v)
{
    int cs;

    %% write init;
    %% write exec;

    if (cs >= EDN_value_first_final) {
        return p;
    }
    else if (cs == EDN_value_error) {
        error(__FUNCTION__, *p);
        return pe;
    }
    else if (cs == EDN_value_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// string parsing - incoming string is raw so interpreting utf
// encodings & unicode values might be necessary. To optimize things a
// bit, we mark the string for encoding if anything outside of the
// ascii range is found.
//
%%{
    machine EDN_string;
    include EDN_common;

    write data;

    action parse_string {
        if (Parser::parse_byte_stream(p_save + 1, p, v, encode)) {
            fexec p + 1;
        } else {
            fhold; fbreak;
        }
    }

    action mark_for_encoding {
        encode = true;
    }

    main := string_delim (
                          (^([\"\\] | 0..0x1f | 0xc2..0xf5) |
                           ((0xc2..0xf5) |
                            '\\'[\"\\/bfnrt] |
                            '\\u'[0-9a-fA-F]{4}) $mark_for_encoding |
                           '\\'^([\"\\/bfnrtu]|0..0x1f))* %parse_string
                          ) :>> string_delim @err(close_err) @exit;
}%%


const char* edn::Parser::parse_string(const char *p, const char *pe, VALUE& v)
{
    static const char* EDN_TYPE = "string";
    int cs;
    bool encode = false;

    %% write init;
    const char* p_save = p;
    %% write exec;

    if (cs >= EDN_string_first_final) {
        return p + 1;
    }
    else if (cs == EDN_string_error) {
        return pe;
    }
    else if (cs == EDN_string_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// keyword parsing
//
%%{
    machine EDN_keyword;
    include EDN_common;

    keyword_start = alpha | [\.\*!_\?$%&<>\=+\-\'\#];
    keyword_chars = (keyword_start | digit | ':');

    keyword_name  = keyword_start keyword_chars*;
    keyword       = keyword_name ('/' keyword_chars*)?;

    write data;


    main := begin_keyword keyword (^(keyword_chars | '/')? @exit);
}%%


const char* edn::Parser::parse_keyword(const char *p, const char *pe, VALUE& v)
{
    int cs;

    %% write init;
    const char* p_save = p;
    %% write exec;

    if (cs >= EDN_keyword_first_final) {
        std::string buf;
        uint32_t len = p - p_save;
        // don't include leading ':' because the ruby symbol will handle it
        buf.append(p_save + 1, len - 1);
        v = ID2SYM(rb_intern(buf.c_str()));
        return p;
    }
    else if (cs == EDN_keyword_error) {
        error(__FUNCTION__, "invalid keyword", *p);
        return pe;
    }
    else if (cs == EDN_keyword_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// decimal parsing machine
//
%%{
    machine EDN_decimal;
    include EDN_common;

    write data noerror;


    main := ('-'|'+')? (
                        (integer '.' digit* (exp? [M]?)) |
                        (integer exp)
                        ) (^[0-9Ee.+\-M]? @exit );
}%%


const char* edn::Parser::parse_decimal(const char *p, const char *pe, VALUE& v)
{
    int cs;

    %% write init;
    const char* p_save = p;
    %% write exec;

    if (cs >= EDN_decimal_first_final) {
        v = Parser::float_to_ruby(p_save, p - p_save);
        return p + 1;
    }
    else if (cs == EDN_decimal_en_main) {} // silence ragel warning
    return NULL;
}


// ============================================================
// integer parsing machine
//
%%{
    machine EDN_integer;
    include EDN_common;

    write data noerror;


    main := (
             ('-'|'+')? (integer [MN]?)
             ) (^[0-9MN+\-]? @exit);
}%%

const char* edn::Parser::parse_integer(const char *p, const char *pe, VALUE& v)
{
    int cs;

    %% write init;
    const char* p_save = p;
    %% write exec;

    if (cs >= EDN_integer_first_final) {
        v = Parser::integer_to_ruby(p_save, p - p_save);
        return p + 1;
    }
    else if (cs == EDN_integer_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// operator parsing - handles tokens w/ a leading operator:
//
// 1. symbols w/ leading operator: -something, .somethingelse
// 2. number values w/ leading - or +
// 3. stand-alone operators: +, -, /, *, etc.
//
%%{
    machine EDN_operator;
    include EDN_common;

    write data;

    action parse_symbol {
        // parse a symbol including the leading operator (-, +, .)
        VALUE sym = Qnil;
        const char *np = parse_symbol(p_save, pe, sym);
        if (np == NULL) { fhold; fbreak; } else {
            v = Parser::make_edn_symbol(sym);
            fexec np;
        }
    }

    action parse_number {
        // parse a number with the leading symbol - this is slightly
        // different than the one within EDN_value since it includes
        // the leading - or +
        //
        // try to parse a decimal first
        const char *np = parse_decimal(p_save, pe, v);
        if (np == NULL) {
            // if we can't, try to parse it as an int
            np = parse_integer(p_save, pe, v);
        }

        if (np) {
            fexec np;
            fhold;
            fbreak;
        }
        else {
            error(__FUNCTION__, *p);
            fexec pe;
        }
    }

    action parse_operator {
        // stand-alone operators (-, +, /, ... etc)
        char op[2] = { *p_save, 0 };
        VALUE sym = rb_str_new2(op);
        v = Parser::make_edn_symbol(sym);
    }

    valid_non_numeric_chars = alpha|operators|':'|'#';
    valid_chars             = valid_non_numeric_chars | digit;

    main := (
             ('-'|'+') begin_number >parse_number |
             (operators - [\-\+\.]) valid_chars >parse_symbol |
             [\-\+\.] valid_non_numeric_chars valid_chars >parse_symbol |
             operators ignore* >parse_operator
             ) ^(valid_chars)? @exit;
}%%


const char* edn::Parser::parse_operator(const char *p, const char *pe, VALUE& v)
{
    int cs;

    %% write init;
    const char* p_save = p;
    %% write exec;

    if (cs >= EDN_operator_first_final) {
        return p;
    }
    else if (cs == EDN_operator_error) {
        error(__FUNCTION__, *p);
        return pe;
    }
    else if (cs == EDN_operator_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// escaped char parsing - handles \c, \newline, \formfeed, etc.
//
%%{
    machine EDN_escaped_char;
    include EDN_common;

    write data;

    valid_chars = extend;


    main := begin_char (
                        'space' | 'newline' | 'tab' | 'return' | 'formfeed' | 'backspace' |
                        valid_chars
                        ) (ignore* | [\\\]\}\)])? @exit;
}%%


const char* edn::Parser::parse_esc_char(const char *p, const char *pe, VALUE& v)
{
    int cs;

    %% write init;
    const char* p_save = p;
    %% write exec;

    if (cs >= EDN_escaped_char_first_final) {
        // convert the escaped value to a character
        if (!Parser::parse_escaped_char(p_save + 1, p, v)) {
            return pe;
        }
        return p;
    }
    else if (cs == EDN_escaped_char_error) {
        error(__FUNCTION__, "unexpected value", *p);
        return pe;
    }
    else if (cs == EDN_escaped_char_en_main) {} // silence ragel warning
    return NULL;
}




// ============================================================
// symbol parsing - handles identifiers that begin with an alpha
// character and an optional leading operator (name, -today,
// .yesterday)
//
//
%%{
    machine EDN_symbol;
    include EDN_common;

    write data;

    symbol_start = alpha | [\.\*!_\?$%&<>\=+\-\'];
    symbol_chars = symbol_start | digit | ':' | '#';
    symbol_name  = (
                    (alpha symbol_chars*) |
                    ([\-\+\.] symbol_start symbol_chars*) |
                    ([/\*!_\?$%&<>\=\'] symbol_chars+) |
                    operators{1}
                    );
    symbol       = '/' | (symbol_name ('/' symbol_name)?);


    main := (
             symbol
             ) ignore* (^(symbol_chars | '/')? @exit);
}%%


const char* edn::Parser::parse_symbol(const char *p, const char *pe, VALUE& s)
{
    int cs;

    %% write init;
    const char* p_save = p;
    %% write exec;

    if (cs >= EDN_symbol_first_final) {
        // copy the symbol text
        if (s == Qnil)
            s = rb_str_new2("");
        rb_str_cat(s, p_save, p - p_save);
        return p;
    }
    else if (cs == EDN_symbol_error) {
        error(__FUNCTION__, *p);
        return pe;
    }
    else if (cs == EDN_symbol_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// EDN_sequence_common is used to parse EDN containers - elements are
// initially stored in an array and then the final corresponding
// container is built from the list (although, for vectors, lists, and
// sets the same array is used)
//
%%{
    machine EDN_sequence_common;
    include EDN_common;

    action open_seq {
        // sequences store elements in an array, then process it to
        // convert it to a list, set, or map as needed once the
        // sequence end is reached
        elems = rb_ary_new();
        // additionally, metadata for elements in the sequence may be
        // carried so we must push a new level in the metadata stack
        new_meta_list();
    }

    action close_seq {
        // remove the current metadata level
        del_top_meta_list();
    }

    action parse_item {
        // reads an item within a sequence (vector, list, map, or
        // set). Regardless of the sequence type, an array of the
        // items is built. Once done, the sequence parser will convert
        // if needed
        VALUE e;
        std::size_t meta_sz = meta_size();
        const char *np = parse_value(fpc, pe, e);
        if (np == NULL) { fhold; fbreak; } else {
            // if there's an entry in the discard list, the current
            // object is not meant to be kept due to a #_ so don't
            // push it into the list of elements
            if (!discard.empty()) {
                discard.pop_back();
            }
            else if (!meta_empty()) {
                // check if parse_value added metadata
                if (meta_size() == meta_sz) {
                    // there's metadata and it didn't increase so
                    // parse_value() read an element we care
                    // about. Bind the metadata to it and add it to
                    // the sequence
                    e = bind_meta_to_value(e);
                    rb_ary_push(elems, e);
                }
            } else {
                // no metadata.. just push it
                rb_ary_push(elems, e);
            }
            fexec np;
        }
    }

    element       = begin_value >parse_item;
    next_element  = ignore* element;
    sequence      = ((element ignore*) (next_element ignore*)*);
}%%

//
// vector-specific machine
%%{
    machine EDN_vector;
    include EDN_sequence_common;

    end_vector     = ']';

    write data;

    main := begin_vector @open_seq (
                                    ignore* sequence? :>> end_vector @close_seq
                                    ) @err(close_err) @exit;
}%%


//
// vector parsing
//
const char* edn::Parser::parse_vector(const char *p, const char *pe, VALUE& v)
{
    static const char* EDN_TYPE = "vector";

    int cs;
    VALUE elems; // will store the vector's elements - allocated in @open_seq

    %% write init;
    %% write exec;

    if (cs >= EDN_vector_first_final) {
        v = elems;
        return p + 1;
    }
    else if (cs == EDN_vector_error) {
        error(__FUNCTION__, *p);
        return pe;
    }
    else if (cs == EDN_vector_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// list parsing machine
//
%%{
    machine EDN_list;
    include EDN_sequence_common;

    end_list       = ')';

    write data;

    main := begin_list @open_seq (
                                  ignore* sequence? :>> end_list @close_seq
                                  ) @err(close_err) @exit;
}%%

//
// list parsing
//
const char* edn::Parser::parse_list(const char *p, const char *pe, VALUE& v)
{
    static const char* EDN_TYPE = "list";

    int cs;
    VALUE elems; // stores the list's elements - allocated in @open_seq

    %% write init;
    %% write exec;

    if (cs >= EDN_list_first_final) {
        v = elems;
        return p + 1;
    }
    else if (cs == EDN_list_error) {
        error(__FUNCTION__, *p);
        return pe;
    }
    else if (cs == EDN_list_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// hash parsing
//
%%{
    machine EDN_map;
    include EDN_sequence_common;

    end_map        = '}';

    write data;


    main := begin_map @open_seq (
                                 ignore* (sequence)? :>> end_map @close_seq
                                 ) @err(close_err) @exit;
}%%


const char* edn::Parser::parse_map(const char *p, const char *pe, VALUE& v)
{
    static const char* EDN_TYPE = "map";

    int cs;
    // since we don't know whether we're looking at a key or value,
    // initially store all elements in an array (allocated in @open_seq)
    VALUE elems;

    %% write init;
    %% write exec;

    if (cs >= EDN_map_first_final) {

        // hash parsing is done. Make sure we have an even count
        if ((RARRAY_LEN(elems) % 2) != 0) {
            error(__FUNCTION__, "odd number of elements in map");
            return pe;
        }

        // now convert the sequence to a hash
        VALUE rslt = rb_hash_new();
        while (RARRAY_LEN(elems) > 0)
        {
            VALUE k = rb_ary_shift(elems);
            rb_hash_aset(rslt, k, rb_ary_shift(elems));
        }

        v = rslt;
        return p + 1;
    }
    else if (cs == EDN_map_error) {
        return pe;
    }
    else if (cs == EDN_map_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// dispatch - handles all tokens with a leading #, then delegates to
// the corresponding machine. This machine consumes the # and passes
// the remaining data to the correct parser
//
%%{
    machine EDN_dispatch;
    include EDN_common;

    write data;

    action parse_set {
        // #{ }
        const char *np = parse_set(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_discard {
        // discard token #_
        const char *np = parse_discard(fpc, pe);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }

    action parse_tagged {
        // #inst, #uuid, or #user/tag
        const char *np = parse_tagged(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else fexec np;
    }


    main := (
             ('{' >parse_set |
              '_' >parse_discard |
              alpha >parse_tagged)
             ) @exit;
}%%


const char* edn::Parser::parse_dispatch(const char *p, const char *pe, VALUE& v)
{
    int cs;

    %% write init;
    %% write exec;

    if (cs >= EDN_dispatch_first_final) {
        return p + 1;
    }
    else if (cs == EDN_dispatch_error) {
        error(__FUNCTION__, *p);
        return pe;
    }
    else if (cs == EDN_dispatch_en_main) {} // silence ragel warning

    return NULL;
}


// ============================================================
// set parsing machine
//
%%{
    machine EDN_set;
    include EDN_sequence_common;

    write data;

    begin_set    = '{';
    end_set      = '}';

    main := begin_set @open_seq (
                                 ignore* sequence? :>> end_set @close_seq
                                 ) @err(close_err) @exit;
}%%

//
// set parsing
//
const char* edn::Parser::parse_set(const char *p, const char *pe, VALUE& v)
{
    static const char* EDN_TYPE = "set";

    int cs;
    VALUE elems; // holds the set's elements as an array allocated in @open_seq

    %% write init;
    %% write exec;

    if (cs >= EDN_set_first_final) {
        // all elements collected; now convert to a set
        v = Parser::make_ruby_set(elems);
        return p + 1;
    }
    else if (cs == EDN_set_error) {
        error(__FUNCTION__, *p);
        return pe;
    }
    else if (cs == EDN_set_en_main) {} // silence ragel warning
    return NULL;
}



// ============================================================
// discard - consume the discard token and parse the next value to
// discard. TODO: perhaps optimize this so no object data is built by
// defining a machine to consume items within container delimiters
//
%%{
    machine EDN_discard;
    include EDN_common;

    write data;

    begin_discard = '_';

    action discard_value {
        const char *np = parse_value(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else {
            // this token is to be discarded so store it in the
            // discard stack - we really don't need to save it so this
            // could be simplified
            discard.push_back(v);
            fexec np;
        }
    }

    action discard_err {
        std::stringstream s;
        s << "discard sequence without element to discard";
        error(__FUNCTION__, s.str());
        fhold; fbreak;
    }

    main := begin_discard ignore* (
                                   begin_value >discard_value
                                   ) @err(discard_err) @exit;
}%%


const char* edn::Parser::parse_discard(const char *p, const char *pe)
{
    int cs;
    VALUE v;

    %% write init;
    %% write exec;

    if (cs >= EDN_discard_first_final) {
        return p + 1;
    }
    else if (cs == EDN_discard_error) {
        error(__FUNCTION__, *p);
        return pe;
    }
    else if (cs == EDN_discard_en_main) {} // silence ragel warning

    return NULL;
}



// ============================================================
// tagged element parsing - #uuid, #inst, #{, #user/tag
//
// Current implementation expects a symbol followed by a value to
// match it against and does not check validity of uuid or rfc3339
// date characters.
//
// TODO:
// 1. need to check if we must support discard shenanigans such as
//
//    #symbol #_ discard data
//
// 2. add parse checks for uuid and inst for better error reporting
//
%%{
    machine EDN_tagged;
    include EDN_common;

    tag_symbol_chars_start = alpha;
    tag_symbol_chars       = tag_symbol_chars_start | [\-_];
    tag_symbol_name        = tag_symbol_chars_start (tag_symbol_chars)*;
    tag_symbol             = (tag_symbol_name ('/' tag_symbol_name)?);

#    inst = (string_delim [0-9+\-:\.TZ]* string_delim);
#    uuid = (string_delim [a-f0-9\-]* string_delim);

    write data;

    action parse_tag {
        // parses the symbol portion of the pair
        const char *np = parse_symbol(fpc, pe, sym_name);
        if (np == NULL) { fhold; fbreak; } else { fexec np; }
    }
    action parse_data {
        // parses the value portion
        const char *np = parse_value(fpc, pe, data);
        if (np == NULL) { fhold; fbreak; } else { fexec np; }
    }


    main := (tag_symbol >parse_tag ignore* begin_value >parse_data) @exit;
}%%


const char* edn::Parser::parse_tagged(const char *p, const char *pe, VALUE& v)
{
    VALUE sym_name = Qnil;
    VALUE data = Qnil;

    int cs;

    %% write init;
    %% write exec;

    if (cs >= EDN_tagged_first_final) {
        //std::cerr << __FUNCTION__ << " parse symbol name as '" << sym_name << "', value is: " << data << std::endl;

        try {
            // tagged_element makes a call to ruby which may throw an
            // exception when parsing the data
            v = Parser::tagged_element(sym_name, data);
        } catch (std::exception& e) {
            error(__FUNCTION__, e.what());
            return pe;
        }
        return p + 1;
    }
    else if (cs == EDN_tagged_error) {
        return pe;
    }
    else if (cs == EDN_tagged_en_main) {} // silence ragel warning
    return NULL;
}




// ============================================================
// metadata - looks like ruby just discards this but we'll track it
// and provide a means to retrive after each parse op - might be
// useful?
//
%%{
    machine EDN_meta;
    include EDN_common;

    write data;

    action parse_meta {
        const char *np = parse_value(fpc, pe, v);
        if (np == NULL) { fhold; fbreak; } else { fexec np; }
    }

    main := begin_meta (
                        begin_value >parse_meta
                        ) @exit;
}%%


const char* edn::Parser::parse_meta(const char *p, const char *pe)
{
    int cs;
    VALUE v;

    %% write init;
    %% write exec;

    if (cs >= EDN_meta_first_final) {
        append_to_meta(v);
        return p + 1;
    }
    else if (cs == EDN_meta_error) {
        error(__FUNCTION__, *p);
        return pe;
    }
    else if (cs == EDN_meta_en_main) {} // silence ragel warning

    return NULL;
}



// ============================================================
// parses entire input but expects single valid token at the
// top-level, therefore, does not tokenize source stream
//
%%{
    machine EDN_parser;
    include EDN_common;

    write data;

    action parse_elem {
        // save the count of metadata items before we parse this value
        // so we can determine if we've read another metadata value or
        // an actual data item
        std::size_t meta_sz = meta_size();
        const char* np = parse_value(fpc, pe, result);
        if (np == NULL) { fexec pe; fbreak; } else {
            // if we have metadata saved and it matches the count we
            // saved before we parsed a value, then we must bind the
            // metadata sequence to it
            if (!meta_empty() && meta_size() == meta_sz) {
                // this will empty the metadata sequence too
                result = bind_meta_to_value(result);
            }
            fexec np;
        }
    }

    element       = begin_value >parse_elem;
    next_element  = ignore* element;
    sequence      = ((element ignore*) (next_element ignore*)*);

    main := ignore* sequence? ignore*;
}%%


VALUE edn::Parser::parse(const char* src, std::size_t len)
{
    int cs;
    VALUE result = EDNT_EOF;

    %% write init;
    set_source(src, len);
    %% write exec;

    if (cs == EDN_parser_error) {
        if (p)
            error(__FUNCTION__, *p);
        return EDNT_EOF;
    }
    else if (cs == EDN_parser_first_final) {
        p = pe = eof = NULL;
    }
    else if (cs == EDN_parser_en_main) {} // silence ragel warning
    return result;
}


// ============================================================
// token-by-token machine
//
%%{
    machine EDN_tokens;
    include EDN_common;

    write data nofinal noerror;

    action parse_token {
        // we won't know if we've parsed a discard or a metadata until
        // after parse_value() is done. Save the current number of
        // elements in the metadata sequence; then we can check if it
        // grew or if the discard sequence grew
        meta_sz = meta_size();

        const char* np = parse_value(fpc, pe, value);
        if (np == NULL) { fhold; fbreak; } else {
            if (!meta_empty()) {
                // was an additional metadata entry read? if so, don't
                // return a value
                if (meta_size() > meta_sz) {
                    state = TOKEN_IS_META;
                }
                else {
                    // a value was read and there's a pending metadata
                    // sequence. Bind them.
                    value = bind_meta_to_value(value);
                    state = TOKEN_OK;
                }
            } else if (!discard.empty()) {
                // a discard read. Don't return a value
                state = TOKEN_IS_DISCARD;
            } else {
                state = TOKEN_OK;
            }
            fexec np;
        }
    }

    main := ignore* begin_value >parse_token ignore*;
}%%


//
//
edn::Parser::eTokenState edn::Parser::parse_next(VALUE& value)
{
    int cs;
    eTokenState state = TOKEN_ERROR;
    // need to track metadada read and bind it to the next value read
    // - but must account for sequences of metadata values
    std::size_t meta_sz;

    // clear any previously saved discards; only track if read during
    // this op
    discard.clear();

    %% write init;
    %% write exec;

    if (cs == EDN_tokens_en_main) {} // silence ragel warning
    return state;
}


/*
 * Local variables:
 * mode: c
 * c-file-style: ruby
 * indent-tabs-mode: nil
 * End:
 */
