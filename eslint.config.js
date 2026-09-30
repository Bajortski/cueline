const globals = require("globals");

module.exports = [
  {
    files: ["iina/src/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: { iina: "readonly", setTimeout: "readonly", clearTimeout: "readonly", setInterval: "readonly", clearInterval: "readonly", module: "writable", require: "readonly" },
    },
  },
  {
    files: ["test/js/**/*.js", "eslint.config.js"],
    languageOptions: { ecmaVersion: 2022, sourceType: "commonjs", globals: globals.node },
  },
  {
    rules: {
      complexity: ["error", 10],
      "no-unused-vars": ["error", { args: "none" }],
      "no-undef": "error",
      eqeqeq: "error",
    },
  },
];
