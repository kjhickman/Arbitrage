
ARBITRAGE_CONFIG = {
	["note"] = "a brace } and the text ARBITRAGE_DATABASE = { live inside this string",
	["enabled"] = true,
}
ARBITRAGE_DATABASE = {
	["__version"] = 2,
	["meta"] = {
		["lastReplicateScan"] = 1700000000,
	},
	["realms"] = {
		["Test Realm"] = {
			["region"] = 1,
			["markets"] = {
				["Alliance"] = {
					["meta"] = {
						["lastScan"] = 1700000100,
						["lastPlayed"] = 1700000050,
					},
					["items"] = {
						["2589"] = {
							["scans"] = {
								[1699913700] = 1300,
								[1700000100] = 1234,
							},
						},
						["equip:12345:1234"] = {
							["scans"] = {
								[1700000100] = 50000,
							},
						},
					},
					["latestBuyouts"] = {
						["2589"] = 1200,
					},
				},
			},
			["vendorPrices"] = {
				["Alliance"] = {
					["2589"] = 10,
				},
			},
		},
	},
}
ARBITRAGE_RECIPES = {
	["note"] = "opaque to the companion",
}
