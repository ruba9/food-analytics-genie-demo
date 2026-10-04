import json
from pathlib import Path


ROOT = Path(__file__).parents[2]
MODEL = ROOT / "powerbi" / "FoodAnalytics.SemanticModel" / "definition"
REPORT = ROOT / "powerbi" / "FoodAnalytics.Report"


def tables() -> dict[str, str]:
    return {p.stem: p.read_text(encoding="utf-8") for p in (MODEL / "tables").glob("*.tmdl")}


def test_model_imports_rather_than_direct_queries() -> None:
    """Import from the SQL warehouse is the customer's standard, not DirectQuery."""
    for name, text in tables().items():
        assert "mode: import" in text, name
        assert "directQuery" not in text, name
        assert "Databricks.Catalogs" in text, name


def test_metrics_are_defined_as_dax_measures() -> None:
    """The semantic model owns the metric definitions, not the Databricks views."""
    sales = tables()["Sales Analytics"]

    assert "measure 'Net Revenue'" in sales
    assert "measure 'Gross Margin %'" in sales

    # Ratio of sums, not an average of per-row percentages.
    assert "DIVIDE([Gross Margin], [Net Revenue])" in sales


def test_model_reads_the_shared_views() -> None:
    sources = " ".join(tables().values())

    assert 'Name="sales_analytics"' in sources
    assert 'Name="waste_analytics"' in sources

    # The model must not bypass the shared views and bind straight to the facts.
    assert 'Name="fact_sales"' not in sources
    assert 'Name="fact_food_waste"' not in sources


def test_report_binds_to_the_local_semantic_model() -> None:
    pbir = json.loads((REPORT / "definition.pbir").read_text(encoding="utf-8"))

    assert pbir["datasetReference"]["byPath"]["path"] == "../FoodAnalytics.SemanticModel"


def test_report_declares_a_base_theme() -> None:
    """themeCollection is required by the PBIR schema; without it Desktop opens a blank canvas."""
    report = json.loads((REPORT / "definition" / "report.json").read_text(encoding="utf-8"))

    base = report["themeCollection"]["baseTheme"]
    assert base["name"] and base["reportVersionAtImport"]
    assert base["type"] == "SharedResources"


def test_report_visuals_are_valid_json_and_use_measures() -> None:
    visuals = list((REPORT / "definition" / "pages").rglob("visual.json"))
    assert len(visuals) >= 6

    for path in visuals:
        payload = json.loads(path.read_text(encoding="utf-8"))
        assert payload["name"], path

    cards = [json.loads(p.read_text(encoding="utf-8")) for p in visuals if "kpi" in p.parts[-2]]
    assert cards, "expected KPI cards"

    # Cards must bind to measures; binding to a raw column would bypass the definition.
    for card in cards:
        projections = card["visual"]["query"]["queryState"]["Values"]["projections"]
        assert all("Measure" in p["field"] for p in projections), card["name"]

        # Abbreviated values (3.59M) cannot be compared with the agent's exact answer.
        labels = card["visual"]["objects"]["labels"][0]["properties"]
        assert labels["labelDisplayUnits"]["expr"]["Literal"]["Value"] == "1D", card["name"]


def test_no_visual_mixes_unrelated_tables() -> None:
    """Sales and Waste Analytics have no relationship, so a Sales axis cannot slice a Waste measure.

    Mixing them repeats the unfiltered waste total on every category or month.
    """
    for path in (REPORT / "definition" / "pages").rglob("visual.json"):
        state = json.loads(path.read_text(encoding="utf-8"))["visual"].get("query", {}).get("queryState", {})
        entities = {
            p["field"][kind]["Expression"]["SourceRef"]["Entity"]
            for role in state.values()
            for p in role["projections"]
            for kind in ("Column", "Measure")
            if kind in p["field"]
        }
        assert not {"Sales Analytics", "Waste Analytics"} <= entities, path.parent.name
