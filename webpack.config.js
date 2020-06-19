const path = require("path");
const copy = require("copy-webpack-plugin");
const extract = require("mini-css-extract-plugin");
const fs = require("fs");
const webpack = require("webpack");
const CompressionPlugin = require("compression-webpack-plugin");

var externals = {
    "cockpit": "cockpit",
};

/* Они могут быть отменены, как правило, из Makefile.am */
const srcdir = (process.env.SRCDIR || __dirname) + path.sep + "src";
const builddir = (process.env.SRCDIR || __dirname);
const distdir = builddir + path.sep + "dist";
const section = process.env.ONLYDIR || null;
const nodedir = path.resolve((process.env.SRCDIR || __dirname), "node_modules");

/* Стандартный nodejs и шаблон webpack */
var production = process.env.NODE_ENV === 'production';

var info = {
    entries: {
        "index": [
            "./index.js"
        ]
    },
    files: [
        "index.html",
        "manifest.json",
    ],
};

var output = {
    path: distdir,
    filename: "[name].js",
    sourceMapFilename: "[file].map",
};

/*
 * Обратите внимание, что мы избегаем использования path.join в качестве webpack и nodejs
 * хочу относительные пути, которые начинаются с ./ явно.
 *
 * Кроме того, мы имитируем функциональность в стиле VPATH в GNU Makefile
 * где мы сначала проверяем builddir, а затем srcdir.
 */

function vpath(/* ... */) {
    var filename = Array.prototype.join.call(arguments, path.sep);
    var expanded = builddir + path.sep + filename;
    if (fs.existsSync(expanded))
        return expanded;
    expanded = srcdir + path.sep + filename;
    return expanded;
}

/* Уточните все пути в записях */
Object.keys(info.entries).forEach(function(key) {
    if (section && key.indexOf(section) !== 0) {
        delete info.entries[key];
        return;
    }

    info.entries[key] = info.entries[key].map(function(value) {
        if (value.indexOf("/") === -1)
            return value;
        else
            return vpath(value);
    });
});

/* Укажите все пути в файлах в списке */
var files = [];
info.files.forEach(function(value) {
    if (!section || value.indexOf(section) === 0)
        files.push({ from: vpath("src", value), to: value });
});
info.files = files;

var plugins = [
    new copy(info.files),
    new extract({filename: "[name].css"})
];

/* Минимизировать только в режиме производства */
if (production) {
    /* Переименовать выходные файлы при сворачивании */
    output.filename = "[name].min.js";

    plugins.unshift(new CompressionPlugin({
        asset: "[path].gz[query]",
        test: /\.(js|html)$/,
        minRatio: 0.9,
        deleteOriginalAssets: true
    }));
}

var babel_loader = {
    loader: "babel-loader",
    options: {
        presets: [
            ["@babel/env", {
                "targets": {
                    "chrome": "57",
                    "firefox": "52",
                    "safari": "10.3",
                    "edge": "16",
                    "opera": "44"
                }
            }],
            "@babel/preset-react"
        ]
    }
}

module.exports = {
    mode: production ? 'production' : 'development',
    resolve: {
        modules: [ nodedir ],
    },
    entry: info.entries,
    externals: externals,
    output: output,
    devtool: "source-map",
    module: {
        rules: [
            {
                enforce: 'pre',
                exclude: /node_modules/,
                loader: 'eslint-loader',
                test: /\.(js|jsx)$/
            },
            {
                exclude: /node_modules/,
                use: babel_loader,
                test: /\.(js|jsx)$/
            },
            /* HACK: удалить ненужные шрифты из PatternFly's css */
            {
                test: /patternfly-4-cockpit.scss$/,
                use: [
                    extract.loader,
                    {
                        loader: 'css-loader',
                        options: {
                            sourceMap: true,
                            url: false
                        }
                    },
                    {
                        loader: 'string-replace-loader',
                        options: {
                            multiple: [
                                {
                                    search: /src:url\("patternfly-icons-fake-path\/pficon[^}]*/g,
                                    replace: "src:url('fonts/patternfly.woff')format('woff');",
                                },
                                {
                                    search: /@font-face[^}]*patternfly-fonts-fake-path[^}]*}/g,
                                    replace: '',
                                },
                            ]
                        },
                    },
                    {
                        loader: 'sass-loader',
                        options: {
                            sourceMap: true,
                            outputStyle: 'compressed',
                        },
                    },
                ]
            },
            {
                test: /\.s?css$/,
                exclude: /patternfly-4-cockpit.scss/,
                use: [
                    extract.loader,
                    {
                        loader: 'css-loader',
                        options: {
                            sourceMap: true,
                            url: false
                        }
                    },
                    {
                        loader: 'sass-loader',
                        options: {
                            sourceMap: true,
                            outputStyle: 'compressed',
                        },
                    },
                ]
            },
        ]
    },
    plugins: plugins
}
