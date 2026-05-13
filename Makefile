.PHONY: deps compile fmt fmt-check lint test test.integration regression ci publish

deps:
	mix deps.get

compile:
	mix compile --warnings-as-errors

fmt:
	mix format

fmt-check:
	mix format --check-formatted

lint:
	mix lint

test:
	mix test

test.integration:
	mix test --include integration

regression:
	bash test/regression.sh

ci: lint test

publish:
	mix hex.publish --yes
