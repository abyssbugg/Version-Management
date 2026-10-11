#!/usr/bin/env python3
from flask import Flask, jsonify

app = Flask(__name__)

@app.route('/healthz')
def healthz():
    return jsonify({'status': 'healthy'}), 200

@app.errorhandler(404)
def not_found(e):
    return '', 404

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000, debug=False)
