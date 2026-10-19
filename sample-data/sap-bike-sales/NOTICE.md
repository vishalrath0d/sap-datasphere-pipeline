# SAP Datasphere "Bike Sales" sample content

Source: https://github.com/SAP-samples/datasphere-content (folder `Sample_Bikes_Sales_content`,
commit 695af09, 2026-05-28). Copyright (c) 2023 SAP SE or an SAP affiliate company.
Licensed under the Apache License 2.0 - see `LICENSE` in this folder.

- `Bike Sales Model.json` - SAP's E/R model export: 9 local tables with associations (unchanged).
- `*.csv` - SAP's sample data for those tables (unchanged).

`definitions/local-tables/*.json` in this repo were generated from the model file with
`scripts/py/import_csn.py` (one file per object, CLI annotation shape). The views in
`definitions/views/` are this repo's own, built on top of SAP's tables.
