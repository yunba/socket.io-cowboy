all: deps compile

deps:
	./rebar get-deps

compile:
	./rebar compile

eunit:	
	./rebar eunit
