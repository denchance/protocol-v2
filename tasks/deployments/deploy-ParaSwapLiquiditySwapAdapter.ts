import { task } from 'hardhat/config';

import { ParaSwapLiquiditySwapAdapterFactory } from '../../types';
import { verifyContract } from '../../helpers/etherscan-verification';
import { getFirstSigner } from '../../helpers/contracts-getters';

const CONTRACT_NAME = 'ParaSwapLiquiditySwapAdapter';

task(`deploy-${CONTRACT_NAME}`, `Deploys the ${CONTRACT_NAME} contract`)
  .addParam('provider', 'Address of the LendingPoolAddressesProvider')
  .addFlag('verify', `Verify ${CONTRACT_NAME} contract via Etherscan API.`)
  .setAction(async ({ provider, verify }, localBRE) => {
    await localBRE.run('set-DRE');

    if (!localBRE.network.config.chainId) {
      throw new Error('INVALID_CHAIN_ID');
    }

    console.log(`\n- ${CONTRACT_NAME} deployment`);
    const adapter = await new ParaSwapLiquiditySwapAdapterFactory(
      await getFirstSigner()
    ).deploy(provider);
    await adapter.deployTransaction.wait();
    console.log(`${CONTRACT_NAME}.address`, adapter.address);
    await verifyContract(adapter.address, [provider]);

    console.log(`\tFinished ${CONTRACT_NAME} deployment`);
  });