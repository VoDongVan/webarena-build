import os
from flask import Flask, render_template

app = Flask(__name__)

BASE = os.path.dirname(os.path.abspath(__file__))


def _read_node(name, fallback="not-running"):
    """Read a node hostname from a .{name}_node file written by its SLURM job."""
    path = os.path.join(BASE, f".{name}_node")
    try:
        return open(path).read().strip() or fallback
    except FileNotFoundError:
        return fallback


def get_hosts():
    # Node files take precedence; hosts.conf env vars are the fallback.
    return {
        "shopping_host":       _read_node("shopping",       os.environ.get("SHOPPING_HOST", "not-running")),
        "shopping_admin_host": _read_node("shopping_admin", os.environ.get("SHOPPING_ADMIN_HOST", "not-running")),
        "reddit_host":         _read_node("reddit",         os.environ.get("REDDIT_HOST", "not-running")),
        "gitlab_host":         _read_node("gitlab",         os.environ.get("GITLAB_HOST", "not-running")),
        "wikipedia_host":      _read_node("wikipedia",      os.environ.get("WIKIPEDIA_HOST", "not-running")),
        "map_host":            _read_node("map",            os.environ.get("MAP_HOST", "not-running")),
    }


@app.route("/")
def index():
    return render_template("index.html", **get_hosts())


@app.route("/scratchpad.html")
def scratchpad():
    return render_template("scratchpad.html")


@app.route("/calculator.html")
def calculator():
    return render_template("calculator.html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=4399)
