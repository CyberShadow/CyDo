import config from "../../../vitest.config";

export default {
  ...config,
  test: {
    ...config.test,
    include: ["src/test-support/fixtures/timeoutIsolation.fixture.ts"],
  },
};
