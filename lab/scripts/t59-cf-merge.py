#!/usr/bin/env python3
"""Lay a distribution configuration from t59-cloudfront.sh over the live one (for `sync`).

  t59-cf-merge.py LIVE.json < NEW.json > MERGED.json

CloudFront's update takes the whole configuration, including every field a creation defaults,
so the new one is merged into the live one key by key: list items matched by their identifying
field (an origin's Id, a behaviour's PathPattern, an error response's ErrorCode), and a new item
starting from a copy of the live list's last.
"""
import json
import sys


def merge(live, new):
	if isinstance(live, dict) and isinstance(new, dict):
		return {**live, **{k: merge(live.get(k), v) for k, v in new.items()}}
	if isinstance(new, list) and new and all(isinstance(x, dict) for x in new) and isinstance(live, list):
		key = next((k for k in ("Id", "PathPattern", "ErrorCode", "OriginId", "EventType") if k in new[0]), None)
		if key:
			by = {x.get(key): x for x in live if isinstance(x, dict)}
			proto = live[-1] if live else None
			return [merge(by.get(x[key], proto), x) for x in new]
	return new


if __name__ == "__main__":
	print(json.dumps(merge(json.load(open(sys.argv[1])), json.load(sys.stdin))))
