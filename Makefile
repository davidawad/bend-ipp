.PHONY: test

# Pure codec checks against the captured printer fixtures; no network.
test:
	bend tests/test_ipp.bend
