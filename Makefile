.PHONY: compile rel cover test dialyzer eqc distclean
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

eqc:
	$(REBAR) eqc

xref:
	$(REBAR) xref

PULSE_TESTING_TIME ?= 30

pulse: compile
	mkdir -p .pulse
	cp eqc/pulse/Emakefile .pulse
	cp _build/default/lib/bitcask/ebin/bitcask.app .pulse
	(cd .pulse; \
		erl -make; \
		erl -noshell -s bitcask_pulse run_tests $(PULSE_TESTING_TIME))

check: test dialyzer xref
