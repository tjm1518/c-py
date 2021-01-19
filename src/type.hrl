type -> uchar_t   : '$1'.
type -> schar_t   : '$1'.
type -> char_t    : '$1'.
type -> l_double  : '$1'.
type -> ulong_t   : '$1'.
type -> long_t    : '$1'.
type -> uint_t    : '$1'.
type -> int_t     : '$1'.
type -> float_t   : '$1'.
type -> double_t  : '$1'.
type -> void      : '$1'.
type -> typedef_t : '$1'.
type -> struct_t  : '$1'.
type -> enum_t    : '$1'.

ulong_t -> unsigned long int : {ulong, element(2, '$1')}.
ulong_t -> unsigned long     : {ulong, element(2, '$1')}.

long_t -> signed long int : {long, element(2, '$1')}.
long_t -> signed long     : {long, element(2, '$1')}.
long_t -> long int        : {long, element(2, '$1')}.
long_t -> long            : '$1'.

int_t -> signed int : {int, element(2, '$1')}.
int_t -> signed     : {int, element(2, '$1')}.
int_t -> int        : '$1'.

uint_t -> unsigned int : {uint, element(2, '$1')}.
uint_t -> unsigned     : {uint, element(2, '$1')}.

schar_t -> signed char : {schar, element(2, '$1')}.

uchar_t -> unsigned char : {uchar, element(2, '$1')}.

char_t -> char : '$1'.

l_double -> long double : {ldouble, element(2, '$1')}.

float_t -> float : '$1'.

double_t -> double : '$1'.

typedef_t -> ident : {typedef_t, element(2, '$1')}.

struct_t -> struct ident '{' struct_l '}' : {struct_t, element(2, '$1'), element(3, '$2'), {struct_l, '$4'}}.
struct_t -> union  ident '{' struct_l '}' : {struct_t, element(2, '$1'), element(3, '$2'), {struct_l, '$4'}}.
struct_t -> struct ident                  : {struct_t, element(2, '$1'), element(3, '$2')}.
struct_t -> union  ident                  : {struct_t, element(2, '$1'), element(3, '$2')}.

struct_l -> struct_d struct_l : ['$1' | '$2'].
struct_l -> struct_d          : ['$1'].

struct_d -> sp_qual st_de_l : [type ]

sp_qual -> type sp_qual : ['$1' | '$2'].
sp_qual -> qual sp_qual : ['$1' | '$2'].
sp_qual -> type : ['$1'].
sp_qual -> qual : ['$1'].

st_de_l -> st_decl : ['$1'].
st_de_l -> st_decl st_de_l : ['$1'|'$2'].

st_decl -> decl ':' const_expr : {st_decl, '$1', '$2'}
st_decl -> decl                : {st_decl, '$1'}.

enum_t -> enum ident '{' enum_l '}' : {enum_t, element(2, '$1'), element(3, '$2'), {enum_l, '$4'}}.
enum_t -> enum ident : {enum_t, element(2, '$1'), element(3, '$2')}.

enum_l -> enum_c enum_l : ['$1' | '$2'].
enum_l -> enum_c        : ['$1'].

enum_c -> ident : '$1'.