const chalk = require('chalk');
const execa = require("execa");
const tar = require("tar");
const fs = require('fs');
const fse = require("fs-extra");
const { resolve } = require("path");
const { config } = require('process');

const filePath = (pathName) => {
  if (pathName) {
    return resolve(process.cwd(), pathName);
  }

  return resolve(process.cwd());
}

const log = (msg, color='green') => {
  console.log(chalk[color](msg));
}

module.exports.log = log;

module.exports.filePath = filePath;

module.exports.downloadLatesVersion = async () => {
  log('Downloading erxes ...');

  // download the latest build
  await fse.copy(
    resolve("/Users/batamar/Downloads/build.tar"),
    filePath('build.tar')
  );

  process.chdir(filePath());

  log('Extracting tar ...');

  await tar.x({ file: "build.tar" });

  log('Removing temp files ...');

  await fse.remove(filePath('build.tar'));
}

const runCommand = (command, args, options) => {
  return execa(command, args, options).stdout.pipe(process.stdout);
}

module.exports.startBackendServices = (configs) => {
  log('Starting backend services using pm2 ...');

  const {
    JWT_TOKEN_SECRET,
    DOMAIN,
    API_DOMAIN,
    WIDGETS_DOMAIN,
    INTEGRATIONS_API_DOMAIN,
    MONGO_URL,
    ELASTICSEARCH_URL,
    ELK_SYNCER,

    RABBITMQ_HOST,
    REDIS_HOST,
    REDIS_PORT,
    REDIS_PASSWORD
  } = configs;

  const optionalDbConfigs = {};

  if (RABBITMQ_HOST) {
    optionalDbConfigs.RABBITMQ_HOST = RABBITMQ_HOST;
  }

  if (REDIS_HOST) {
    optionalDbConfigs.REDIS_HOST = REDIS_HOST;
    optionalDbConfigs.REDIS_PORT = REDIS_PORT;
    optionalDbConfigs.REDIS_PASSWORD = REDIS_PASSWORD;
  }

  const commonEnv = {
    NODE_ENV: 'production',
    JWT_TOKEN_SECRET: JWT_TOKEN_SECRET || '',
    MONGO_URL: `${MONGO_URL || ''}/erxes`,
    MAIN_APP_DOMAIN: DOMAIN,
    WIDGETS_DOMAIN: WIDGETS_DOMAIN,
    INTEGRATIONS_API_DOMAIN: INTEGRATIONS_API_DOMAIN,
    ...configs.API || {}
  }

  log('Starting main api ...');

  runCommand("pm2", ["start", filePath('build/api')], {
    env: {
      ...commonEnv,
      ...optionalDbConfigs,
      DEBUG: 'erxes-api:*', 
    }
  });

  log('Starting crons ...');

  runCommand("pm2", ["start", filePath('build/api/cronJobs')], {
    env: {
      ...commonEnv,
      PROCESS_NAME: 'crons',
      ...optionalDbConfigs,
      DEBUG: 'erxes-crons:*', 
    }
  });

  log('Starting workers ...');

  runCommand("pm2", ["start", filePath('build/api/workers')], {
    env: {
      ...commonEnv,
      ...optionalDbConfigs,
      DEBUG: 'erxes-workers:*', 
    }
  });

  log('Starting integrations ...');

  runCommand("pm2", ["start", filePath('build/integrations')], {
    env: {
      NODE_ENV: 'production',
      DEBUG: 'erxes-integrations:*',
      DOMAIN: INTEGRATIONS_API_DOMAIN,
      MAIN_APP_DOMAIN: DOMAIN,
      MAIN_API_DOMAIN: API_DOMAIN,
      MONGO_URL: `${MONGO_URL || ''}/erxes_integrations`,
      ...optionalDbConfigs,
      ...configs.INTEGRATIONS || {}
    }
  });

  log('Starting engages ...');

  runCommand("pm2", ["start", filePath('build/engages')], {
    env: {
      NODE_ENV: 'production',
      DEBUG: 'erxes-engages:*',
      DOMAIN: INTEGRATIONS_API_DOMAIN,
      MAIN_API_DOMAIN: API_DOMAIN,
      MONGO_URL: `${MONGO_URL || ''}/erxes_engages`,
      ...optionalDbConfigs,
      ...configs.ENGAGES || {}
    }
  });

  log('Starting logger ...');

  runCommand("pm2", ["start", filePath('build/logger')], {
    env: {
      NODE_ENV: 'production',
      DEBUG: 'erxes-logs:*',
      DOMAIN: INTEGRATIONS_API_DOMAIN,
      MAIN_API_DOMAIN: API_DOMAIN,
      MONGO_URL: `${MONGO_URL || ''}/erxes_logger`,
      ...optionalDbConfigs,
      ...configs.LOGGER || {}
    }
  });

  log('Starting email verifier ...');

  runCommand("pm2", ["start", filePath('build/email-verifier')], {
    env: {
      NODE_ENV: 'production',
      DEBUG: 'erxes-email-verifier:*',
      MONGO_URL: `${MONGO_URL || ''}/erxes_email_verifier`,
      ...configs.EMAIL_VERIFIER || {}
    }
  });

  if (ELK_SYNCER) {
    runCommand('pip', ['install', '-r', 'build/elkSyncer/requirements.txt']);

    runCommand("pm2", ["start", filePath('build/elkSyncer/main.py'), '--interpreter', '/usr/bin/python3'], {
      env: {
        MONGO_URL,
        ELASTICSEARCH_URL
      }
    });
  }
}

module.exports.startUI = async (configs) => {
  const uiConfigs = configs.UI || {};

  if (uiConfigs.disableServe) {
    return log('Default serve is disabled. Please serve using services like nginx, aws s3 ...', 'yellow');
  }

  log('Starting ui using serve ...');

  const { API_DOMAIN, WIDGETS_DOMAIN } = configs;
  const subscriptionsUrl = `${API_DOMAIN.includes('https') ? 'wss' : 'ws'}//${API_DOMAIN}/subscriptions`;

  await fs.promises.writeFile(filePath('build/ui/js/env.js'), `
    window.env = {
      NODE_ENV: "production",
      REACT_APP_API_URL: "${API_DOMAIN}",
      REACT_APP_API_SUBSCRIPTION_URL: "${subscriptionsUrl}",
      REACT_APP_CDN_HOST: "${WIDGETS_DOMAIN}"
    }
  `);

  runCommand("serve", ['-s', '-p', uiConfigs.PORT, filePath('build/ui')]);

  log('Starting widgets ...');

  runCommand("pm2", ["--name", "widgets", "start", filePath('build/widgets/dist')], {
    env: {
      ...configs.WIDGETS || {},
      NODE_ENV: 'production',
      ROOT_URL: WIDGETS_DOMAIN,
      API_URL: API_DOMAIN,
      API_SUBSCRIPTIONS_URL: subscriptionsUrl,
    }
  });
}