import { task } from 'hardhat/config';
import { checkVerification } from '../../helpers/etherscan-verification';
import { ConfigNames } from '../../helpers/configuration';
import { printContracts } from '../../helpers/misc-utils';

task('arc-dev:mumbai', 'Deploy development enviroment')
  .addFlag('verify', 'Verify contracts at Etherscan')
  .setAction(async ({ verify }, localBRE) => {
    const POOL_NAME = ConfigNames.ArcMumbai;

    await localBRE.run('set-DRE');

    // Prevent loss of gas verifying all the needed ENVs for Etherscan verification
    if (verify) {
      checkVerification();
    }

    console.log('Migration started\n');

    console.log('1. Deploy mock tokens');
    await localBRE.run('dev:deploy-mock-tokens', { verify });

    console.log('2. Deploy address provider');
    await localBRE.run('dev:deploy-address-provider', { verify, skipRegistry: true });

    console.log('3. Deploy lending pool');
    await localBRE.run('dev:deploy-lending-pool', { verify, pool: POOL_NAME });

    console.log('4. Deploy oracles');
    await localBRE.run('dev:deploy-oracles', { verify, pool: POOL_NAME });

    console.log('6. Deploy Permissioned WETH Gateway');
    await localBRE.run('full-deploy-permissioned-weth-gateway', { pool: POOL_NAME });

    console.log('6. Initialize lending pool');
    await localBRE.run('dev:initialize-lending-pool', { verify, pool: POOL_NAME });

    console.log('\nFinished migration');
    printContracts();
  });