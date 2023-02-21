pragma solidity ^0.8.0;

import "test/helpers/IntegrationTest.sol";

contract TestIntegrationMorphoEMode is IntegrationTest {
    function testMorphoEModeOnAave() public {
        assertEq(E_MODE_CATEGORY_ID, pool.getUserEMode(address(morphoProxy)));
    }
}
