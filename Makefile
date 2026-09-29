.PHONY: compile clean distclean cover test dialyzer xref check
# rebar3 from PATH: the repo no longer vendors ./rebar3.
REBAR ?= rebar3

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

# `rebar3 clean` keeps the C++ objects in _build/cmake (a full libbitcask
# rebuild takes minutes). distclean wipes them too — also the way to switch
# CMake generators (Makefiles → Ninja) on an existing checkout.
distclean: clean
	rm -rf _build/cmake

cover: test
	$(REBAR) cover

test: compile
	$(REBAR) eunit

dialyzer:
	$(REBAR) dialyzer

xref:
	$(REBAR) xref

check: test dialyzer xref
